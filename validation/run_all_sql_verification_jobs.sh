#!/usr/bin/env bash

jobs_dir=$1
logs_dir=$2
tag=$3 # eg "before"

find "${jobs_dir}" -type f -name "*.sql" | while read sql_file ; do 
  job_name="$(basename ${sql_file})"
  log_file="${logs_dir}/${tag}_${job_name}.log" 
  echo "[INFO] Executing ${job_name} (log: ${log_file})"
  execute_sql_on_prod "$sql_file" > "$log_file"
done

