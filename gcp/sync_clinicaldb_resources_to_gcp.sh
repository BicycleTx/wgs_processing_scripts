#!/usr/bin/env bash

set -e
source message_functions

BUCKET="gs://clinicaldb-resources-prod-1"

info "Syncing clinicaldb resources to GCP"
gcloud auth activate-service-account --key-file /data/common/dbs/gcp_credentials/hmf-ops
gsutil cp /data/ecrf/cpct_ecrf.xml ${BUCKET}/cpct_ecrf.xml
gsutil cp /data/ecrf/cpct_form_status.csv ${BUCKET}/cpct_form_status.csv 
gsutil cp /data/ecrf/drup_ecrf.xml ${BUCKET}/drup_ecrf.xml
gsutil -m cp /data/ops/lims/prod/* ${BUCKET}/lims
gsutil cp /data/common/dbs/clinical_data/curated_primary_tumor.tsv ${BUCKET}/curated_primary_tumor.tsv
gsutil cp /data/common/dbs/clinical_data/patient_tumor_curation_status.tsv ${BUCKET}/patient_tumor_curation_status.tsv 
gsutil cp /data/common/dbs/disease_ontology/201015_doid.json ${BUCKET}/201015_doid.json 
gsutil cp /data/common/dbs/clinical_curation/tumor_location_mapping.tsv ${BUCKET}/tumor_location_mapping.tsv 
gsutil cp /data/common/dbs/clinical_curation/treatment_mapping.tsv ${BUCKET}/treatment_mapping.tsv 
gsutil cp /data/common/dbs/clinical_curation/biopsy_site_mapping.tsv ${BUCKET}/biopsy_site_mapping.tsv 
gsutil cp /data/common/dbs/clinical_curation/tumor_location_overrides.tsv ${BUCKET}/tumor_location_overrides.tsv
info "Clinicaldb resources synced"
