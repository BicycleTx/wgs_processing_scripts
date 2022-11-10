#!/usr/bin/env bash

source message_functions || exit 1
source locate_reporting_api || exit 1

sampleId=$1

if [[ -z ${sampleId} ]]; then
    error "No sample name provided"
fi

echo "--TAT information for sample ${sampleId}--"


#### Last material arrival date ###

temp_nr=$( lama patients/tumorsamples $sampleId | head -n1 | grep -o '^.*arrivalHmf' | wc -w )
tumor_arrival=$( lama patients/tumorsamples $sampleId | awk '{ print $'${temp_nr}' }' | grep -v arrivalHmf )

sampleId_ref=$( echo $( echo $sampleId | cut -f1 -d'T' )"R" )
temp_nr=$( lama patients/bloodsamples $sampleId_ref | head -n1 | grep -o '^.*arrivalHmf' | wc -w )
ref_arrival=$( lama patients/bloodsamples $sampleId_ref | awk '{ print $'${temp_nr}' }' | grep -v arrivalHmf )

if [ $(echo $tumor_arrival | wc -w) == 0 ]; then
	echo "Tumor material not yet arrived."
	exit
fi

if [ $(echo $ref_arrival | wc -w) == 0 ]; then
	echo "Reference material not yet arrived."
	exit
fi


if [ "$tumor_arrival" > "$ref_arrival" ]; then
	start=$tumor_arrival
else
    start=$ref_arrival
fi

start_sec=$( date --date=$start +%s )


##### Determine whether sample was already reported

barcode=$( hmf_api_get samples?name=${sampleId} | jq -r .[].barcode )
report_created_id=$( extract_most_recent_reporting_id_on_barcode $barcode )
reported=$( hmf_api_get reports/shared?report_created_id=${report_created_id}  | jq .[] | jq -r '.share_time' | tr 'T' ' ' | sed 's/\s.*$//')

if [ $(echo $reported | wc -w) > 0 ]; then
    echo "This OncoAct has been reported on:"
    echo $reported
    echo "The TAT of reporting was:"
    reported_sec=$( date --date=$reported +%s )
    echo $(( ($reported_sec - $start_sec )/(60*60*24) ))
    exit
fi


##### If not reported the current TAT

now_sec=$(date +%s)
echo "This sample is still in process!"
echo "The current TAT is:"
echo $(( ($now_sec - $start_sec )/(60*60*24) ))