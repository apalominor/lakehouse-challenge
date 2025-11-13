import sys
import yaml
import boto3
from datetime import datetime
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F

# Retrieving parameters
args = getResolvedOptions(sys.argv,["JOB_NAME", "source_bucket", "destination_bucket", "input_path", "output_path", "database_name"])

job_name = args["JOB_NAME"]
source_bucket = args["source_bucket"]
destination_bucket = args["destination_bucket"]
input_path = args["input_path"]
database_name = args["database_name"]
table_name = "customers"
output_path_param = args["output_path"]
output_path = f"{output_path_param}/{table_name}"

# Initialize
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(job_name, args)

# Reading CSV files
print(f"Leyendo desde: {input_path}")

df = spark.read.format("csv").option("header", "true").option("inferSchema", "true").load(input_path)
total_records = df.count()
print(f"Total de Registros: {total_records}")
df.printSchema()

# Partition column selection (based on known data)
partition_col = "created_at"

# YAML Schema file creation
schema_yaml = {
    "dataset": table_name,
    "description": "Dataset de Customers",
    "format": "csv",
    "target_format": "parquet",
    "partition_by": partition_col or "none",
    "schema": [],
    "access_level": {
        "tag_key": "stage",
        "tag_value": "analytics"
    }
}

for field in df.schema.fields:
    schema_yaml["schema"].append({
        "name": field.name,
        "type": str(field.dataType)
    })

# Change types to make them familiar
type_map = {
    "StringType": "string",
    "IntegerType": "int",
    "LongType": "long",
    "DoubleType": "double",
    "TimestampType": "timestamp",
    "DateType": "date"
}

for col in schema_yaml["schema"]:
    for spark_type, yaml_type in type_map.items():
        if spark_type in col["type"]:
            col["type"] = yaml_type

# Saving YAML file
yaml_str = yaml.dump(schema_yaml, sort_keys=False, allow_unicode=True)
config_key = f"schema/{table_name}_config.yaml"

s3 = boto3.client("s3")
s3.put_object(
    Bucket=destination_bucket,
    Key=config_key,
    Body=yaml_str.encode("utf-8"),
    ContentType="text/yaml"
)

print(f"Config YAML generado en s3://{destination_bucket}/{config_key}")

# Storing in HUDI format
print(f" Escribiendo datos en formato Hudi a: {output_path}")

df = df.withColumn(partition_col, F.to_date(F.col(partition_col)))
df = df.withColumn("ingestion_date", F.current_timestamp())

additional_options={
    "hoodie.table.name": table_name,
    "hoodie.database.name": database_name,
    "hoodie.datasource.write.storage.type": "COPY_ON_WRITE",
    "hoodie.datasource.write.operation": "upsert",
    "hoodie.datasource.write.recordkey.field": "customer_id",
    "hoodie.datasource.write.precombine.field": "ingestion_date",
    "hoodie.datasource.write.partitionpath.field": partition_col,
    "hoodie.datasource.write.hive_style_partitioning": "true",
    "hoodie.datasource.hive_sync.enable": "true",
    "hoodie.datasource.hive_sync.database": database_name,
    "hoodie.datasource.hive_sync.table": table_name,
    "hoodie.datasource.hive_sync.partition_fields": partition_col,
    "hoodie.datasource.hive_sync.partition_extractor_class": "org.apache.hudi.hive.MultiPartKeysValueExtractor",
    "hoodie.datasource.hive_sync.use_jdbc": "false",
    "hoodie.datasource.hive_sync.mode": "hms",
    "hoodie.datasource.meta_sync.condition.sync": "true"
}

df.write.format("hudi").options(**additional_options).mode("overwrite").save(output_path)

print("Glue Job Completado")

job.commit()
