#!/usr/bin/env bash

#put metadata file path at $1.

# make dir for temporary files
mkdir temp_number_check

### Read in patients and samples selected for DR
csvcut -t -e iso-8859-1 -c '#patientId' $1  | csvformat -T | tail -n +2 | sort | uniq > temp_number_check/patientId_metadata.tsv
csvcut -t -e iso-8859-1 -c 'sampleId' $1  | csvformat -T | tail -n +2 | sort | uniq > temp_number_check/sampleId_metadata.tsv

echo "[INFO] Number of patients (based on study number) in metadata file:"
wc -l temp_number_check/patientId_metadata.tsv
echo "[INFO] Number of samples (based on study number) in metadata file:"
wc -l temp_number_check/sampleId_metadata.tsv
