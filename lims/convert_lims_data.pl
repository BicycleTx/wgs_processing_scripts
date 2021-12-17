#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use File::Basename;
use Getopt::Long;
use File::Slurp;
use JSON::XS;
use Text::CSV;
use File::Copy;
use Email::Valid;
use POSIX qw(strftime);
use 5.01000;
$| = 1; # Disable stdout buffering

use constant EMPTY => q{ };
use constant NACHAR => 'NA';

# Fields that will actively be set to boolean for json output
use constant BOOLEAN_FIELDS => qw(shallowseq report_germline report_viral report_pgx add_to_database add_to_datarequest);
# Fields that will actively be set to integer for json output
use constant INTEGER_FIELDS => qw(yield q30);
# Fields that will be required to exist in input if checked
my %WARN_IF_ABSENT_IN_LAMA_FIELDS = (_id=>1, status=>1);

my $SCRIPT  = `basename $0`; chomp( $SCRIPT );
my $HELP_TEXT = <<"HELP";

  Description
    Parses LIMS text files (derived from excel and MS Access) and
    writes to JSON output.

  Usage
    $SCRIPT -lims_dir /data/ops/lims/pilot -out_json /data/ops/lims/pilot/lims.json

  Required params:
    -lims_dir <str>  Path to input dir (eg /data/ops/lims/pilot)
    -out_json <str>  Path to output json (eg /data/tmp/lims.json)

HELP

# Get input and setup all paths
my %opt = ();
GetOptions (
    "lims_dir=s" => \$opt{ lims_dir },
    "out_json=s" => \$opt{ out_json },
    "debug"      => \$opt{ debug },
    "help|h"     => \$opt{ help },
) or die("Error in command line arguments\n");

die $HELP_TEXT if $opt{ help };
die $HELP_TEXT unless $opt{ lims_dir };
die $HELP_TEXT unless $opt{ out_json };

my $CNTR_TSV = '/data/ops/lims/prod/center2entity.tsv';
my $LIMS_DIR = $opt{lims_dir};
my $JSON_OUT = $opt{out_json};
my $LATEST_DIR = $LIMS_DIR . "/lab_files/latest";

# Current LIMS files
my $FOR_001_SUBM_TSV = $LATEST_DIR . '/for001_submissions.tsv';
my $FOR_001_CONT_TSV = $LATEST_DIR . '/for001_contacts.tsv';
my $FOR_001_SAMP_TSV = $LATEST_DIR . '/for001_samples.tsv';
my $FOR_002_PROC_TSV = $LATEST_DIR . '/for002_processing.tsv';

# Current LAMA files
my $LAMA_ISOLATION_JSON = $LATEST_DIR . '/Isolations.json';
my $LAMA_PATIENT_JSON = $LATEST_DIR . '/Patients.json';
my $LAMA_LIBRARYPREP_JSON = $LATEST_DIR . '/LibraryPreps.json';
my $LAMA_SAMPLESTATUS_JSON = $LATEST_DIR . '/SampleStatus.json';

# Files from previous years
my $SUBM_TSV_2020 = $LATEST_DIR . '/2020_for001_submissions.tsv';
my $SAMP_TSV_2020 = $LATEST_DIR . '/2020_for001_samples.tsv';
my $PROC_TSV_2020 = $LATEST_DIR . '/2020_for002_processing.tsv';
my $SUBM_TSV_2019 = $LATEST_DIR . '/2019_for001_submissions.tsv';
my $SAMP_TSV_2019 = $LATEST_DIR . '/2019_for001_samples.tsv';
my $PROC_TSV_2019 = $LATEST_DIR . '/2019_for002_processing.tsv';
my $SUBM_TSV_2018 = $LATEST_DIR . '/2018_subm';
my $SAMP_TSV_2018 = $LATEST_DIR . '/2018_samp';
my $PROC_TSV_2018 = $LATEST_DIR . '/2018_proc';
my $PROC_TSV_2017 = $LATEST_DIR . '/2017_proc';
my $LIMS_JSN_2017 = $LATEST_DIR . '/2017_lims.json'; # excel LIMS pre-2018

my @ALL_INPUT_FILES = (
    $LAMA_ISOLATION_JSON, $LAMA_PATIENT_JSON, $LAMA_LIBRARYPREP_JSON, $LAMA_SAMPLESTATUS_JSON,
    $FOR_001_SUBM_TSV, $FOR_001_SAMP_TSV, $FOR_002_PROC_TSV,
    $SUBM_TSV_2020, $SAMP_TSV_2020, $PROC_TSV_2020,
    $SUBM_TSV_2019, $SAMP_TSV_2019, $PROC_TSV_2019,
    $SUBM_TSV_2018, $SAMP_TSV_2018, $PROC_TSV_2018,
    $PROC_TSV_2017, $LIMS_JSN_2017,
    $CNTR_TSV
);

foreach ( $LIMS_DIR ){
    die "[ERROR] Input dir does not exist ($_)\n" unless -e $_;
    die "[ERROR] Input dir is not a directory ($_)\n" unless -d $_;
}
foreach ( @ALL_INPUT_FILES ){
    die "[ERROR] Input file does not exist ($_)\n" unless -f $_;
}
foreach ( $JSON_OUT ){
    die "[ERROR] Output file exists and is not writable ($_)\n" if ( -f $_ and not -w $_ );
}

sayInfo("Starting with $SCRIPT");

my $name_dict = getFieldNameTranslations();
my $cntr_dict = parseDictFile( $CNTR_TSV, 'center2centername' );

my $proc_objs = {}; # will contain objects from InProcess sheet
my $subm_objs = {}; # will contain objects from Received-Samples shipments sheet
my $cont_objs = {}; # will contain objects from Received-Samples contact sheet
my $samp_objs = {}; # will contain objects from Received-Samples samples sheet
my $lims_objs = {}; # will contain all sample objects

$proc_objs = parseTsvCsv( $proc_objs, $name_dict->{'PROC_CURR'}, 'sample_id',  0, $PROC_TSV_2017, "\t" );
$proc_objs = parseTsvCsv( $proc_objs, $name_dict->{'PROC_CURR'}, 'sample_id',  0, $PROC_TSV_2018, "\t" );
$proc_objs = parseTsvCsv( $proc_objs, $name_dict->{'PROC_CURR'}, 'sample_id',  0, $PROC_TSV_2019, "\t" );
$proc_objs = parseTsvCsv( $proc_objs, $name_dict->{'PROC_CURR'}, 'sample_id',  0, $PROC_TSV_2020, "\t" );
$proc_objs = parseTsvCsv( $proc_objs, $name_dict->{'PROC_CURR'}, 'sample_id',  0, $FOR_002_PROC_TSV, "\t" );

$subm_objs = parseTsvCsv( $subm_objs, $name_dict->{'SUBM_2018'}, 'submission', 0, $SUBM_TSV_2018, "\t" );
$subm_objs = parseTsvCsv( $subm_objs, $name_dict->{'SUBM_2019'}, 'submission', 0, $SUBM_TSV_2019, "\t" );
$subm_objs = parseTsvCsv( $subm_objs, $name_dict->{'SUBM_2020'}, 'submission', 0, $SUBM_TSV_2020, "\t" );

$subm_objs = parseTsvCsv( $subm_objs, $name_dict->{'SUBM_CURR'}, 'submission', 0, $FOR_001_SUBM_TSV, "\t" );
$cont_objs = parseTsvCsv( $cont_objs, $name_dict->{'CONT_CURR'}, 'group_id',   1, $FOR_001_CONT_TSV, "\t" );

$samp_objs = parseTsvCsv( $samp_objs, $name_dict->{'SAMP_2018'}, 'sample_id',  1, $SAMP_TSV_2018, "\t" );
$samp_objs = parseTsvCsv( $samp_objs, $name_dict->{'SAMP_2019'}, 'sample_id',  1, $SAMP_TSV_2019, "\t" );
$samp_objs = parseTsvCsv( $samp_objs, $name_dict->{'SAMP_2020'}, 'sample_id',  1, $SAMP_TSV_2020, "\t" );
$samp_objs = parseTsvCsv( $samp_objs, $name_dict->{'SAMP_CURR'}, 'sample_id',  1, $FOR_001_SAMP_TSV, "\t" );

my $lama_status = parseLamaSampleStatus($LAMA_SAMPLESTATUS_JSON);
my $lama_isolation = parseLamaIsolation($LAMA_ISOLATION_JSON);
my $lama_sample = parseLamaPatients($LAMA_PATIENT_JSON);
my $lama_prep = parseLamaLibraryPreps($LAMA_LIBRARYPREP_JSON);

checkContactInfo( $cont_objs );

$subm_objs = addContactInfoToSubmissions( $subm_objs, $cont_objs );
$lims_objs = addExcelSamplesToSamples( $lims_objs, $samp_objs, $subm_objs );
$lims_objs = addLamaSamplesToSamples( $lims_objs, $lama_status, $lama_sample, $lama_isolation, $lama_prep, $subm_objs, $cntr_dict );
$lims_objs = addLabSopStringToSamples( $lims_objs, $proc_objs );

fixAddedDateFields( $lims_objs );
checkDrupStage3Info( $subm_objs, $lims_objs );
printLimsToJson( $lims_objs, $subm_objs, $cont_objs, $JSON_OUT );
sayInfo("Finished with $SCRIPT");

sub addLamaSamplesToSamples{
    my ($lims, $statuses, $samples, $isolations, $preps, $submissions, $centers_dict) = @_;
    my %store = %{$lims};
    my %dna_blood_samples_by_name = ();
    sayInfo("  Adding LAMA samples to LIMS");

    while (my ($isolate_barcode, $object) = each %$statuses) {
        my %sample_to_store = %{$object};
        my $sample_barcode = $sample_to_store{received_sample_id};

        # adding sample info to statuses
        if (exists $samples->{$sample_barcode}) {
            addRecordFieldsToTargetRecord($samples->{$sample_barcode}, \%sample_to_store, "merge of sample info for $isolate_barcode");
            # retaining the roman naming for older samples for the time being (can be removed once anonymization project is finished)
            if (exists $samples->{$sample_barcode}{legacy_sample_name}){
                $sample_to_store{sample_name} = $samples->{$sample_barcode}{legacy_sample_name};
            }
        }

        # adding isolate info to statuses
        if (exists $isolations->{$isolate_barcode}) {
            addRecordFieldsToTargetRecord($isolations->{$isolate_barcode}, \%sample_to_store, "merge of isolate info for $isolate_barcode");
        }

        # adding prep info to statuses
        if (exists $preps->{$isolate_barcode}) {
            addRecordFieldsToTargetRecord($preps->{$isolate_barcode}, \%sample_to_store, "merge of prep info for $isolate_barcode");
        }

        my $sample_name = $sample_to_store{sample_name};
        my ($patient_id, $study, $center, $tum_or_ref);
        my $name_regex = '^((CPCT|DRUP|WIDE|ACTN|CORE)[0-9A-Z]{2}([0-9A-Z]{2})\d{4})(T|R){1}';
        if ($sample_name =~ /$name_regex/ms) {
            ($patient_id, $study, $center, $tum_or_ref) = ($1, $2, $3, $4);
            $sample_to_store{label} = $study;
        }
        else {
            sayWarn("SKIPPING LAMA sample because name ($sample_name) does not fit regex $name_regex");
            next;
        }

        my $original_submission = $sample_to_store{submission};
        my $isolation_type = $sample_to_store{isolation_type};
        my $analysis_type = $sample_to_store{isolation_type};
        my $final_target_yield = NACHAR;

        if (not defined $isolation_type) {
            sayWarn("SKIPPING: no isolation type defined for $isolate_barcode (pls fix in LAMA)");
            next;
        }
        elsif ($isolation_type eq 'Tissue') {
            $analysis_type = 'Somatic_T'; # DNA from tumor tissue
            $final_target_yield = 300;
        }
        elsif ($isolation_type eq 'RNA') {
            $analysis_type = 'RNAanalysis'; # RNA from tumor tissue
            $final_target_yield = 15;
        }
        elsif ($isolation_type eq 'Blood') {
            $analysis_type = 'Somatic_R'; # DNA from blood
            $dna_blood_samples_by_name{ $sample_name } = \%sample_to_store;
            $final_target_yield = 100;
        }
        elsif ($isolation_type eq 'Plasma') {
            $analysis_type = 'PlasmaAnalysis'; # Plasma from blood
        }
        else {
            sayWarn("SKIPPING: unknown isolation type '$isolation_type' for $isolate_barcode (pls fix in LAMA)");
            next
        }

        if ($study eq 'CORE' and $sample_name !~ /^COREDB/) {
            if (not defined $original_submission or $original_submission eq '') {
                if ($analysis_type eq 'Somatic_R') {
                    sayInfo("    No submission id yet for R sample (id:$isolate_barcode name:$sample_name)");
                }
                elsif (not defined $original_submission) {
                    sayWarn("SKIPPING CORE for missing submission id (id:$isolate_barcode name:$sample_name)");
                }
                else{
                    sayWarn("SKIPPING CORE for incorrect submission id \"$original_submission\" (id:$isolate_barcode name:$sample_name)");
                }
                next;
            }
            $sample_to_store{ 'entity' } = $original_submission;
            $sample_to_store{ 'project_name' } = $original_submission;

            # Set the analysis type for CORE submissions to align with Excel LIMS samples
            if (exists $submissions->{ $original_submission }) {
                my $submission_object = $submissions->{ $original_submission };
                my $project_name = $submission_object->{ 'project_name' };
                $sample_to_store{project_name} = $project_name; # Reset project name for sample (from submission)
                $submission_object->{analysis_type} = "OncoAct"; # Add an analysis type to submission
            }
            else {
                sayWarn("Unable to update submission \"$original_submission\" not found in submissions (id:$isolate_barcode name:$sample_name)");
            }
        }
        elsif (exists $centers_dict->{ $center }) {
            # All other samples are clinical study based (CPCT/DRUP/WIDE/ACTN/COREDB)
            my $centername = $centers_dict->{ $center };
            my $register_submission = 'HMFreg' . $study;
            $sample_to_store{original_submission} = $original_submission;
            $sample_to_store{submission} = $register_submission;
            $sample_to_store{project_name} = $register_submission;
            $sample_to_store{entity} = join("_", $study, $centername);
        }
        else {
            sayWarn("SKIPPING sample because is not CORE but center ID is unknown \"$center\" (id:$isolate_barcode name:$sample_name)");
            next;
        }

        # Add the missing fields and store final
        $sample_to_store{analysis_type} = $analysis_type;
        $sample_to_store{original_submission} = $original_submission;
        $sample_to_store{yield} = $final_target_yield;

        # Fix various formats of date fields
        fixDateFields(\%sample_to_store);

        # Fix/translate various field contents
        fixFieldContents(\%sample_to_store, $name_dict->{lama_content_translations_by_field_name});
        $sample_to_store{patient} =~ s/\-//g;
        $sample_to_store{cohort} =~ s/\-//g;

        # Add non-existing fields that might be required for downstream tools to work
        my @fields_that_must_be_present = qw(arrival_date biopsy_site lab_sop_versions ptum report_germline_level);
        foreach my $field (@fields_that_must_be_present){
            if ( not exists $sample_to_store{$field} ){
                $sample_to_store{$field} = "";
            }
        }

        # And store the final result
        storeRecordByKey(\%sample_to_store, $isolate_barcode, \%store, "final storing of $isolate_barcode", 1);
    }

    # Need another loop over all tumor samples to complete ref_sample_id for older samples
    while ( my($barcode, $sample) = each %store ){

        # We can skip non tumor samples and tumor samples where ref_sample_id info is already present
        next unless $sample->{analysis_type} eq 'Somatic_T';
        next if (defined $sample->{'ref_sample_id'} and $sample->{'ref_sample_id'} ne "");

        # Otherwise try to complete info by searching for R sample
        my $patient_string = $sample->{ 'patient' };
        $patient_string =~ s/\-//g; # string this point still with dashes
        my $ref_sample_name = $patient_string . 'R';
        if ( exists $dna_blood_samples_by_name{ $ref_sample_name } ){
            my $ref_sample_id = $dna_blood_samples_by_name{ $ref_sample_name }{ 'sample_id' };
            $sample->{'ref_sample_id'} = $ref_sample_id;
        }
    }
    return \%store;
}

sub fixFieldContents{
    my ($record, $translation_dict) = @_;
    while ( my($key, $translations) = each %$translation_dict ){
        if ( exists $record->{$key} ){
            my $val = $record->{$key};
            if ( exists $translations->{$val} ){
                $record->{$key} = $translations->{$val};
            }
        }
    }
}

sub storeRecordByKey{
    my ($record, $key, $store, $info_tag, $do_not_warn_if_exists) = @_;
    if (exists $store->{$key} and not $do_not_warn_if_exists){
        sayWarn("Store key already exists in store and will be overwritten ($key for $info_tag)");
    }
    my %copy_of_record = %$record;
    $store->{$key} = \%copy_of_record;
}

sub addRecordFieldsToTargetRecord{
    my ($record, $target_record) = @_;
    while (my ($key, $val) = each %$record){
        $target_record->{$key} = $val;
    }
}

sub copyFieldsFromObject{
    my ($object, $info_tag, $fieldsTranslationTable, $store) = @_;

    while (my ($src_key, $tgt_key) = each %$fieldsTranslationTable){
        if (exists $object->{$src_key}){
            $store->{$tgt_key} = $object->{$src_key};
        }
        elsif(exists $WARN_IF_ABSENT_IN_LAMA_FIELDS{$src_key}){
            sayWarn("No '$src_key' field in object ($info_tag)");
        }
    }
}

sub epochToDate{
    my ($epoch) = @_; # epoch time in milliseconds
    my $registrationDate = strftime "%Y-%m-%d", localtime $epoch/1000;
    return $registrationDate;
}

sub parseLamaPatients {
    my ($inputJsonFile) = @_;
    my %store = ();
    my $objects = readJson($inputJsonFile);

    foreach my $patient (@$objects) {
        foreach my $sample (@{$patient->{tumorSamples}}) {
            processSampleOfLamaPatient($patient, $sample, 'tumor', \%store);
        }
        foreach my $sample (@{$patient->{bloodSamples}}) {
            processSampleOfLamaPatient($patient, $sample, 'blood', \%store);
        }
    }
    return \%store;
}

sub processSampleOfLamaPatient {
    my ($patient, $sample, $sample_origin, $store) = @_;
    my $sample_field_translations;
    my @sampleBarcodes;

    if( $sample_origin eq 'tumor' ){
        $sample_field_translations = $name_dict->{lama_patient_tumor_sample_dict};
        @sampleBarcodes = @{$sample->{sampleBarcodes}};
    }
    elsif( $sample_origin eq 'blood' ){
        $sample_field_translations = $name_dict->{lama_patient_blood_sample_dict};
        @sampleBarcodes = ($sample->{sampleBarcode});
    }
    else{
        my $sample_barcode = $sample->{sampleBarcode};
        die "[ERROR] Unknown sample origin provided to processSampleOfPatient ($sample_origin for $sample_barcode)\n";
    }

    my %info = ();
    my $info_tag = "patients->barcodes=" . join("|", @sampleBarcodes);

    copyFieldsFromObject($sample, $info_tag, $sample_field_translations, \%info);
    copyFieldsFromObject($patient, $info_tag, $name_dict->{lama_patient_dict}, \%info);

    foreach my $sampleBarcode (@sampleBarcodes) {
        storeRecordByKey(\%info, $sampleBarcode, $store, "patient_samples");
    }
}

sub parseLamaLibraryPreps{
    my ($inputJsonFile) = @_;
    my %store = ();
    my $objects = readJson($inputJsonFile);

    foreach my $experiment (@$objects) {

        foreach my $object (@{$experiment->{libraries}}) {
            my $store_key = $object->{_id};
            my $status = $object->{status};

            # Only store prep info when OK
            next if $status =~ m/failed/i;

            my %info = ();
            my $info_tag = "libraryprep->$store_key";
            copyFieldsFromObject($object, $info_tag, $name_dict->{lama_libraryprep_library_dict}, \%info);
            storeRecordByKey(\%info, $store_key, \%store, "libraryprep", 1);
        }
    }
    return \%store;
}

sub parseLamaIsolation{
    my ($inputJsonFile) = @_;
    my %store = ();
    my $objects = readJson($inputJsonFile);

    foreach my $experiment (@$objects) {

        # When isolation experiment is Processing there are no frBarcodes yet so skip all isolates
        next if $experiment->{status} eq "Processing";

        foreach my $isolate (@{$experiment->{isolates}}) {

            # Once a isolation experiment is no longer Processing there should be a frBarcode
            unless ( exists $isolate->{frBarcode} ) {
                print Dumper $isolate;
                die "[ERROR] No frBarcode present for above isolate object";
            }

            my $barcode = $isolate->{frBarcode};
            my $new_status = $isolate->{status};

            if ( exists $store{$barcode} ) {
                my $old_status = $store{$barcode}{'isolation_status'};
                my $old_is_finished = $old_status eq 'Finished';
                my $new_is_finished = $new_status eq 'Finished';
                if ( $old_is_finished and $new_is_finished ){
                    sayWarn("SKIPPING isolate: encountered duplicate Finished isolate for $barcode (pls fix in LAMA)");
                    print Dumper $store{$barcode};
                    next;
                }
                elsif ( $old_is_finished and not $new_is_finished ){
                    next;
                }
                else{
                    # In this case we simply overwrite a non-Finished status with a Finished one
                }
            }
            my %info = ();
            my $info_tag = "isolation->$barcode";
            copyFieldsFromObject($isolate, $info_tag, $name_dict->{lama_isolation_isolate_dict}, \%info);
            storeRecordByKey(\%info, $barcode, \%store, "isolation", 1);
        }
    }
    return \%store;
}

sub parseLamaSampleStatus{
    my ($inputJsonFile) = @_;
    my %store = ();
    my $objects = readJson($inputJsonFile);

    foreach my $object (@$objects){

        my $sampleBarcodeDNA = $object->{frBarcodeDNA};
        my $sampleBarcodeRNA = $object->{frBarcodeRNA};
        my $sampleId = $object->{sampleId};

        # No DNA frBarcode means sample has not been isolated so skip
        if ( not defined $sampleBarcodeDNA or $sampleBarcodeDNA eq "" ){
            next;
        }

        # Collect all info into one object
        my %status = ();
        my $info_tag = "samplestatus->$sampleBarcodeDNA";
        copyFieldsFromObject($object, $info_tag, $name_dict->{lama_status_dict}, \%status);
        copyFieldsFromObject($object->{cohort}, $info_tag, $name_dict->{lama_status_cohort_dict}, \%status);

        # Store
        $status{'sample_id'} = $object->{frBarcodeDNA};
        storeRecordByKey(\%status, $sampleBarcodeDNA, \%store, "samplestatus->$sampleBarcodeDNA");
        if ( defined $sampleBarcodeRNA and $sampleBarcodeRNA ne "" ){
            $status{'sample_id'} = $object->{frBarcodeRNA};
            storeRecordByKey(\%status, $sampleBarcodeRNA, \%store, "samplestatus->$sampleBarcodeRNA");
        }
    }
    return \%store;
}

sub parseTsvCsv{
    my ($objects, $fields, $store_field_name, $should_be_unique, $file, $sep) = @_;
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1, sep_char => $sep });
    my %store = %$objects;

    sayInfo("  Parsing input CSV/TSV file $file");
    open IN, "<", $file or die "[ERROR] Unable to open file ($file): $!\n";
    my $header_line = <IN>; chomp($header_line);
    die "[ERROR] Cannot parse line ($header_line)\n" unless $csv->parse($header_line);
    my @header_fields = $csv->fields();
    my %fields_map = map { $_ => 1 } @header_fields;

    # Checking header content
    my $header_misses_field = 0;
    foreach my $field (keys %$fields) {
        if ( not exists $fields_map{ $field } ){
            sayWarn("Missing header field ($field) in file ($file)");
            $header_misses_field = 1;
        }
    }
    if ( $header_misses_field ){
        print Dumper \%fields_map and die "[ERROR] Header incomplete ($file)\n";
    }

    # Header OK: continue reading in all data lines
    while ( <IN> ){
        chomp;
        die "[ERROR] Cannot parse line ($_)\n" unless $csv->parse($_);
        my @values = $csv->fields();

        my %raw_object = ();
        foreach my $field ( @header_fields ){
            my $next_value = shift @values;
            $next_value = NACHAR if not defined $next_value;
            $raw_object{ $field } = $next_value;
        }

        my $obj = selectAndRenameFields( \%raw_object, $fields );
        my $key = $obj->{ $store_field_name } || NACHAR;
        my $source = $obj->{ 'sample_source' } || NACHAR;
        my $name = $obj->{ 'sample_name' } || "SampleNameUnknown";

        if ( $source eq 'BLOOD' ){
            $key = $name;
        }

        next if isSkipValue( $key );
        my $reason_not_to_store = checkKeyToStore( \%store, $key );
        if ( $should_be_unique and $reason_not_to_store ){
            sayWarn("SKIPPING object (name: $name) from $file for reason: $reason_not_to_store") and next;
        }

        # Checks OK: fix some fields and store object
        fixDateFields( $obj );
        fixIntegerFields( $obj );
        fixBooleanFields( $obj );
        $store{ $key } = $obj;
    }
    close IN;

    return \%store;
}

sub selectAndRenameFields{
    my ($obj_in, $fields) = @_;
    my %obj_out = ();
    foreach my $key ( keys %$obj_in ){
        if ( defined $fields->{ $key } ){
            $obj_out{ $fields->{$key} } = $obj_in->{ $key };
        }
    }
    return \%obj_out;
}

sub readJson{
    my ($json_file) = @_;
    sayInfo("  Parsing input json file $json_file");
    my $json_txt = read_file( $json_file );
    my $json_obj = decode_json( $json_txt );
    return( $json_obj );
}

sub printLimsToJson{
    my ($samples, $submissions, $contact_groups, $lims_file) = @_;
    my $samp_count = scalar keys %$samples;
    my $subm_count = scalar keys %$submissions;
    my $cont_count = scalar keys %$contact_groups;

    my %lims = ( 'samples' => $samples, 'submissions' => $submissions, 'contact_groups' => $contact_groups );
    my $coder = JSON::XS->new->utf8->canonical;
    my $lims_txt = $coder->encode(\%lims);

    sayInfo("  Writing output to $lims_file ($cont_count contact groups, $subm_count submissions and $samp_count samples)");
    open my $lims_json_fh, '>', $lims_file or die "[ERROR] Unable to open output file ($lims_file): $!\n";
    print $lims_json_fh $lims_txt;
    close $lims_json_fh;
}

sub addLabSopStringToSamples{
    my ($samples, $inprocess) = @_;
    sayInfo("  Adding SOP string information to samples");
    my %store = %$samples;
    my $sop_field_name = 'lab_sop_versions';
    foreach my $id ( keys %store ){
        if ( exists $inprocess->{ $id } ){
            # format: PREP(\d+)V(\d+)-QC(\d+)V(\d+)-SEQ(\d+)V(\d+)
            $store{ $id }{ $sop_field_name } = $inprocess->{ $id }{ $sop_field_name };
        }
        elsif ( defined $samples->{ $id }{ $sop_field_name } ){
            # keep whatever is present
        }
        else{
            # fallback to NA default
            $store{ $id }{ $sop_field_name } = NACHAR;
        }
    }
    return \%store;
}

sub parseDictFile{
    my ($file, $fileType) = @_;
    sayInfo("  Parsing input dictionary file $file");
    my %store = ();

    open my $dict_fh, "<", $file or die "$!: Unable to open file ($file)\n";
    while ( <$dict_fh> ){
        next if /^#/ms;
        chomp;
        if ( $fileType eq 'center2centername' ){
            my ( $id, $descr, $name ) = split /\t/;
            die "[ERROR] id occurs multiple times ($id) in file ($file)\n" if exists $store{ $id };
            $store{ $id } = $name if ( $id ne EMPTY and $name ne EMPTY );
        }
        else{
            die "[ERROR] File type not set or not recognized ($fileType)\n";
        }
    }
    close $dict_fh;

    return \%store;
}

sub addContactInfoToSubmissions{
    my ($submissions, $contact_groups) = @_;
    my @fields = qw(
        requester_report_contact_name
        requester_report_contact_email
        report_contact_name
        report_contact_email
        data_contact_name
        data_contact_email
    );
    sayInfo("  Adding contact group information to submissions");
    my %store = %{$submissions};
    foreach my $submission_id (sort keys %store){
        my $submission = $store{$submission_id};

        if( exists $submission->{ 'requester_report_contact_email' } ){
            # Skip records from the time when contact info was entered in shipments tab
            next;
        }
        elsif( defined $submission->{ 'group_id' } ){
            my $group_id = $submission->{ 'group_id' };
            next if $group_id eq 'na';
            if ( exists $contact_groups->{ $group_id } ){
                my $group = $contact_groups->{ $group_id };
                foreach my $field ( @fields ){
                    $submission->{$field} = $group->{ $field };
                }
            }
            else{
                sayWarn("Submission \"$submission_id\" has group ID \"$group_id\" but not found in contact groups (check Contact tab of FOR-001)");
                next;
            }
        }
        else{
            sayWarn("No Group ID field in place for submission $submission_id");
            next;
        }
    }
    return \%store;
}

sub checkDrupStage3Info{
    my ($submissions, $samples) = @_;
    my $drup_stage3_count = 0;
    my $expected_cohort = 'DRUPstage3';

    sayInfo("  Checking $expected_cohort submissions");
    while (my ($id,$obj) = each %$submissions){
        my $project_type = $obj->{'project_type'};
        my $project_name = $obj->{'project_name'};

        next unless ($project_type eq 'Cohort' and $project_name =~ /DRUP/);

        $drup_stage3_count++;
        my $patient_id = $project_name;
        $patient_id =~ tr/-//d;
        my $sample_name = $patient_id . "T";
        my $sample_count = 0;
        while (my($barcode,$sample) = each %$samples){
            next unless $sample->{'sample_name'} eq $sample_name;
            # need to match case insensitive due to LAMA upper case but excel in lower case
            next unless $sample->{'original_submission'} =~ m/^$id$/i;
            next unless $sample->{'analysis_type'} eq 'Somatic_T';
            my $cohort = $sample->{'cohort'};
            if ( $cohort !~ m/^$expected_cohort$/i ){
                sayWarn("    Found sample for submission $id with incorrect cohort (name:$sample_name id:$barcode cohort:$cohort)");
            }
            $sample_count++;
        }
        sayWarn("    Found no samples for $expected_cohort submission $id!") if $sample_count < 1;
    }
    sayInfo("    Summary: $drup_stage3_count submissions encountered and checked for $expected_cohort");
}

sub checkContactInfo{
    my ($contact_groups) = @_;
    my @name_fields = qw(client_contact_name requester_report_contact_name report_contact_name data_contact_name);
    my @mail_fields = qw(requester_report_contact_email report_contact_email data_contact_email);
    sayInfo("  Checking contact group information for completeness");
    foreach my $id (sort keys %$contact_groups){
        my $info = $contact_groups->{$id};

        # These fields should at the very least have content
        foreach my $field (@name_fields, @mail_fields){
            if ( $info->{$field} eq "" ){
                sayWarn("No content in field \"$field\" for contact group ID \"$id\" (see FOR-001 Contacts tab)");
            }
        }
        # These fields should contain only (valid) email addresses
        foreach my $field (@mail_fields){
            my @addresses = split( ";", $info->{$field});
            foreach my $address (@addresses){
                if( $address eq NACHAR ){
                    next;
                }
                elsif( not Email::Valid->address($address) ){
                    sayWarn("No valid email address ($address) in field '$field' for contact group ID '$id' (see FOR-001 Contacts tab)");
                }
            }
        }
    }
}

sub addExcelSamplesToSamples{

    my ($lims, $objects, $shipments) = @_;
    my %store = %{$lims};

    # Open file and check header before reading data lines
    while ( my($row_key, $row_info) = each %$objects ){

        my $sample_name = $row_info->{ 'sample_name' } or die "[ERROR] No sample_name in row_info";
        next if isSkipValue( $sample_name );

        my $sample_id = $row_info->{ 'sample_id' } or sayWarn("SKIPPING sample ($sample_name): No sample_id found") and next;
        my $submission = $row_info->{ 'submission' } or sayWarn("SKIPPING sample ($sample_name): No submission found") and next;
        my $analysis_type = $row_info->{ 'analysis_type' } or sayWarn("SKIPPING sample ($sample_name): No analysis_type found") and next;

        $row_info->{ 'label' } = 'RESEARCH';
        $row_info->{ 'patient' } = $row_info->{ 'sample_name' };
        $row_info->{ 'entity' } = $row_info->{ 'submission' };

        # Check data analysis type and set accordingly
        if ( $analysis_type =~ /^(Somatic_R|Somatic_T|SingleAnalysis|FASTQ|BCL|LabOnly)$/ ){
            # Already final status so no further action
        }
        elsif ( $sample_name =~ /^(CORE\d{2}\d{6})(T|R){1}/ms ){
            my ($patient, $tum_or_ref) = ($1, $2);
            $row_info->{ 'label' }         = "CORE";
            $row_info->{ 'patient' }       = $patient;
            $row_info->{ 'entity' }        = $submission;
            $row_info->{ 'analysis_type' } = $tum_or_ref eq 'T' ? 'Somatic_T' : 'Somatic_R';
        }
        elsif ( $analysis_type eq 'SomaticAnalysis' or $analysis_type eq 'SomaticsBFX' ){
            # SomaticsBFX is the old term, SomaticAnalysis the new
            my $partner = $row_info->{ 'ref_sample_id' };
            if ( $partner ne '' and $partner ne NACHAR ){
                $row_info->{ 'analysis_type' } = 'Somatic_T';
            }
            else{
                $row_info->{ 'analysis_type' } = 'Somatic_R';
            }

            # Hardcode Somatic_T samples to not use existing ref data for FOR-001 samples
            $row_info->{ 'other_ref' } = "";

            # Hardcode old Somatic_T samples to not run in shallow mode (config was added only in FOR-001 v5.10)
            if ( not exists $row_info->{ 'shallowseq' }) {
                $row_info->{ 'shallowseq' } = JSON::XS::false;
            }

        }
        elsif ( $analysis_type eq 'GermlineBFX' or $analysis_type eq 'Germline' ){
            # GermlineBFX is the old term, SingleAnalysis the new
            $analysis_type = 'SingleAnalysis';
            $row_info->{ 'analysis_type' } = $analysis_type;
        }
        elsif ( $analysis_type eq 'NoBFX' or $analysis_type eq 'NoAnalysis' or $analysis_type eq '' or $analysis_type eq 'NA' ){
            # NoBFX is the old term, FASTQ the new
            $analysis_type = 'FASTQ';
            $row_info->{ 'analysis_type' } = $analysis_type;
        }
        elsif ( $analysis_type eq 'Labonly' ){
            $analysis_type = 'LabOnly';
            $row_info->{ 'analysis_type' } = $analysis_type;
        }
        elsif ( $analysis_type eq 'SNPgenotyping' or $analysis_type eq 'SNP' ){
            $analysis_type = 'SnpGenotyping';
            $row_info->{ 'analysis_type' } = $analysis_type;
        }
        else {
            sayWarn("SKIPPING sample ($sample_name): has unknown analysis type ($analysis_type)");
            next;
        }

        # Add submission info and parse KG
        if ( exists $shipments->{ $submission } ){
            my $sub = $shipments->{ $submission };
            my $project_name = $sub->{ 'project_name' };
            $row_info->{ 'project_name' } = $project_name;

            if ( $sub->{ 'project_type' } eq 'KG production' ){

                my @dvo_parts = split( /\-/, $project_name );
                my $center = uc( $dvo_parts[0] );
                $row_info->{ 'entity' } = 'KG_' . $center;
                $row_info->{ 'label' } = 'KG';
            }
            # Assumes that all samples of submission need same analysis
            $sub->{ 'analysis_type' } = $analysis_type;
        }

        my $unique = $row_info->{ 'sample_id' };
        next if isSkipValue( $unique );

        # Checks before storing
        my $regex = '^[0-9a-zA-Z\-]*$';
        sayWarn("SKIPPING sample ($sample_name): sample_name contains unacceptable chars") and next if $sample_name !~ /$regex/;
        sayWarn("SKIPPING sample ($sample_name): sample_id ($sample_id) contains unacceptable chars") and next if $sample_id !~ /$regex/;
        sayWarn("SKIPPING sample ($sample_name): no submission defined for sample") and next unless $row_info->{ 'submission' };
        sayWarn("SKIPPING sample ($sample_name): no analysis type defined for sample") and next unless $row_info->{ 'analysis_type' };
        sayWarn("SKIPPING sample ($sample_name): no project name defined for sample") and next unless $row_info->{ 'project_name' };

        # Store at unique id
        my $reason_not_to_store = checkKeyToStore( \%store, $unique );
        if ( $reason_not_to_store ){
            sayWarn("SKIPPING sample with name \"$sample_name\" for reason: $reason_not_to_store") and next;
        }
        $store{ $unique } = $row_info;

    }

    return \%store;
}

sub fixIntegerFields{
    my ($obj) = @_;
    foreach my $key ( INTEGER_FIELDS ){
        # Make sure all integer values are stored as such for json export
        if ( exists $obj->{$key} and $obj->{$key} =~ /^\d+$/ ){
            $obj->{$key} = $obj->{$key} + 0;
        }
    }
}

sub fixBooleanFields{
    my ($obj) = @_;
    foreach my $key ( BOOLEAN_FIELDS ){
        next unless exists $obj->{ $key };
        next unless defined $obj->{ $key };
        my $value = $obj->{ $key };
        if ( $value =~ m/^true$/i ){
            $obj->{ $key } = JSON::XS::true;
        }elsif ( $value =~ m/^false$/i ){
            $obj->{ $key } = JSON::XS::false;
        }else{
            sayWarn("Unexpected value ($value) in boolean field ($key)");
        }
    }
}

sub fixAddedDateFields{
    my ($sample_objects) = @_;
    while( my($key, $obj) = each %$sample_objects){
        fixDateFields( $obj );
    }
}

sub fixDateFields{
    my ($obj) = @_;
    my @date_fields = qw( arrival_date sampling_date report_date isolation_date libraryprep_date snpgenotype_date );

    foreach my $date_field ( @date_fields ){

        next unless defined $obj->{ $date_field };
        my $old_date = $obj->{ $date_field };
        my $new_date = $old_date;
        my $identifier = $obj->{ 'sample_name' };

        # Date is not always filled in so skip NA fields
        next if isSkipValue( $old_date );

        # Convert all date strings to same format yyyy-mm-dd (eg 2017-01-31)
        if( $old_date eq '1' ) {
            $new_date = NACHAR;
        }
        elsif( $old_date =~ /^\d{13}$/ ) {
            # eg 1516575600000
            $new_date = epochToDate($old_date)
        }
        elsif( $old_date =~ /^\w+ (\w{3}) (\d{2}) \d+:\d+:\d+ \w+ (\d{4})$/ ){
            # eg Tue Apr 23 00:00:00 CEST 2019
            my $month_name = $1;
            my $day = $2;
            my $year = $3;
            my $month = getMonthIndexByName( $month_name );
            $new_date = join( "-", $year, $month, $day );
        }
        elsif ( $old_date =~ /^(\d{2})(\d{2})(\d{2})$/ ){
            # Format unclear so need for checks
            sayWarn("Date \"$old_date\" in \"$date_field\" has unexpected year ($identifier): please check") if ($1 < 8) or ($1 > 20);
            sayWarn("Date \"$old_date\" in \"$date_field\" has impossible month ($identifier): please fix") if $2 > 12;
            $new_date = join( "-", "20" . $1, $2, $3 );
        }
        elsif ( $old_date =~ /^(\d{2})-(\d{2})-(\d{4})$/ ){
            # case dd-mm-yyyy
            sayWarn("Date \"$old_date\" in \"$date_field\" has impossible month ($identifier): please fix") if $2 > 12;
            $new_date = join( "-", $3, $2, $1 );
        }
        elsif ( $old_date =~ /^(\d{4})-(\d{2})-(\d{2})$/ ){
            # case yyyy-mm-dd already ok
            sayWarn("Date \"$old_date\" in \"$date_field\" has impossible month ($identifier): please fix") if $2 > 12;
        }
        elsif ( exists $old_date->{'$numberLong'}){
            # Older versions of mongo-export use canonical mode and return a hash with numberLong key
            $new_date = epochToDate($old_date->{'$numberLong'})
        }
        else{
            sayWarn("Date string \"$old_date\" in field \"$date_field\" has unknown format for sample ($identifier): kept string as-is but please fix");
        }

        # Store new format using reference to original location
        $obj->{ $date_field } = $new_date;
    }
}

sub getMonthIndexByName{
    my ($month_name) = @_;
    my %mapping = (
        "Jan" => "01", "Feb" => "02", "Mar" => "03", "Apr" => "04",
        "May" => "05", "Jun" => "06", "Jul" => "07", "Aug" => "08",
        "Sep" => "09", "Oct" => "10", "Nov" => "11", "Dec" => "12"
    );
    if ( exists $mapping{ $month_name } ){
        return $mapping{ $month_name };
    }
    else{
        sayWarn("Unknown Month name ($month_name): kept as-is but please fix");
        return $month_name;
    }
}

sub parseExcelSheet{
    my ($config) = @_;

    my $excel = $config->{ 'excel' };
    my $h_val = $config->{ 'h_val' };
    my $h_col = $config->{ 'h_col' };
    my $h_row = $config->{ 'h_row' };
    my $trans = $config->{ 'trans' };
    my $sheet = $config->{ 'sheet' };

    sayInfo("Loading excel file $excel sheet '$sheet'");
    my $workbook = Spreadsheet::XLSX->new( $excel ) or die "[ERROR] Unable to load excel file $excel: $!\n";
    my $sheet_obj = $workbook->worksheet( $sheet ) or die "[ERROR] Unable to read sheet \"$sheet\" from file $excel: $!\n";

    my @header = ();
    my $max_row = $sheet_obj->{'MaxRow'};
    my $max_col = $sheet_obj->{'MaxCol'};

    # Check if header exist where it should be
    my $first_val = EMPTY;
    my $first_cel = $sheet_obj->get_cell( $h_row, $h_col );
    $first_val = $first_cel->unformatted() if defined $first_cel;
    die "[ERROR] Header value ($h_val) cannot be found at set location ($excel)\n" unless $first_val eq $h_val;

    # Now read header values for later storage
    foreach my $col ( $h_col .. $max_col ){
        my $cell = $sheet_obj->get_cell( $h_row, $col );
        my $cell_val = NACHAR;
        $cell_val = $cell->unformatted() if defined $cell;
        $cell_val = $trans->{ $cell_val } if defined $trans->{ $cell_val };
        push( @header, $cell_val );
    }

    return( \@header, $sheet_obj, $max_row, $max_col );
}

sub isSkipValue{
    my ($value) = @_;
    die "[ERROR] Value to check for skipping is not defined\n" if not defined $value;
    my @to_skip = ( NACHAR, EMPTY, '', 'na', 'naR', 'naT', 'invalid', 'failed', 'nvt', 'no', 'x', '#N/A' );
    foreach my $skip_string ( @to_skip ){
        return 1 if $value =~ /^$skip_string$/i;
    }
    return 0;
}

sub checkKeyToStore{
    my ($store, $key) = @_;
    my $failReason = 0;

    if ( not defined $key ){
        $failReason = "key variable is not defined";
    }
    elsif ( isSkipValue($key) ){
        $failReason = "key is string to skip (key: $key)";
    }
    elsif ( $key =~ /[\n\r]/ ){
        my $woNewlines = $key =~ s/[\n\r\f]/\[ENTER\]/gr;
        $failReason = "key contains newline/enter (key: $woNewlines)";
    }
    elsif ( not $key =~ /^[a-zA-z0-9\-]+$/ ){
        $failReason = "key contains characters that are not allowed (key: $key)";
    }
    elsif ( exists $store->{ $key } ){
        $failReason = "duplicate key that should be unique (key: $key)";
    }

    return $failReason;
}

sub checkDefined{
    my ( $key, $hash) = @_;
    if ( not defined $hash->{$key} ){
        sayWarn("Value $key is not defined in:");
        print Dumper $hash;
    }
}

sub sayInfo{
    my ($msg) = @_;
    say "[INFO] " . (strftime "%y%m%d %H:%M:%S", localtime) . " - " . $msg;
}

sub sayWarn{
    my ($msg) = @_;
    warn "[WARN] " . (strftime "%y%m%d %H:%M:%S", localtime) . " - " . $msg . "\n";
}

sub getFieldNameTranslations{
    # Columns contact sheet in current FOR-001
    my %CONT_DICT = (
        "Group_ID"                      => 'group_id',
        "Client_contact_name"           => 'client_contact_name',
        "Client_contact_email"          => 'client_contact_email',
        "On_behalf_of_client_name"      => 'on_behalf_of_client_contact_name',
        "On_behalf_of_client_email"     => 'on_behalf_of_client_contact_email',
        "Report_contact_name"           => 'report_contact_name',
        "Report_contact_email"          => 'report_contact_email',
        "Requester_report_contact_name" => 'requester_report_contact_name',
        "Requester_report_contact_email" => 'requester_report_contact_email',
        "Data_contact_name"      => 'data_contact_name',
        "Data_contact_email"     => 'data_contact_email',
        "Lab_contact_name"       => 'lab_contact_name',
        "Lab_contact_email"      => 'lab_contact_email',
    );

    # Columns shipments sheet in 2018 rest lims (FOR-001)
    my %SUBM_DICT_2018 = (
        "Arrival_date"      => 'arrival_date',
        "Project_name"      => 'project_name',
        "HMF_reg"           => 'submission',
        "Requested_product" => 'request',
        "Product_category"  => 'project_type',
        "Sample_count"      => 'sample_count',
        "Lab_is_finished"   => 'has_lab_finished',
        "TAT_lab"           => 'turn_around_time',
        "Contact_name"      => 'requester_report_contact_name',
        "Contact_email"     => 'requester_report_contact_email',
        "Remarks"           => 'remarks',
        "Storage_status"    => 'lab_storage_status',
    );

    # Columns shipments sheet in 2019 rest lims (FOR-001)
    my %SUBM_DICT_2019 = (
        "Arrival_date"      => 'arrival_date',
        "Project_name"      => 'project_name',
        "HMF_reg"           => 'submission',
        "Requested_product" => 'request',
        "Product_category"  => 'project_type',
        "Sample_count"      => 'sample_count',
        "Lab_is_finished"   => 'has_lab_finished',
        "Group_ID"          => 'group_id',
        "TAT_lab"           => 'turn_around_time',
        "Contact_name"      => 'report_contact_name',
        "Contact_email"     => 'report_contact_email',
        "Portal_contact_name" => 'requester_report_contact_name',
        "Portal_contact_email" => 'requester_report_contact_email',
        "Remarks"           => 'remarks',
        "Storage_status"    => 'lab_storage_status',
    );

    # Columns shipments sheet in rest lims (FOR-001)
    my %SUBM_DICT_2020 = (
        "Arrival_date"      => 'arrival_date',
        "Project_name"      => 'project_name',
        "HMF_reg"           => 'submission',
        "Requested_product" => 'request',
        "Product_category"  => 'project_type',
        "Sample_count"      => 'sample_count',
        "Lab_is_finished"   => 'has_lab_finished',
        "Group_ID"          => 'group_id',
        "Remarks"           => 'remarks',
    );

    # Columns shipments sheet in rest lims (FOR-001)
    my %SUBM_DICT = (
        "Arrival_date"      => 'arrival_date',
        "Project_name"      => 'project_name',
        "HMF_reg"           => 'submission',
        "Requested_product" => 'request',
        "Product_category"  => 'project_type',
        "Sample_count"      => 'sample_count',
        "Lab_is_finished"   => 'has_lab_finished',
        "Group_ID"          => 'group_id',
        "Total_yield_required" => 'total_yield_required',
        "Remarks"           => 'remarks',
    );

    # Columns samples sheet in 2018 FOR-001
    my %SAMP_DICT_2018 = (
        "Sample_ID"         => 'sample_id',
        "Sample_name"       => 'sample_name',
        "DNA_conc"          => 'conc',
        "Yield"             => 'yield',
        "Q30"               => 'q30',
        "Analysis_type"     => 'analysis_type',
        "Partner_sample"    => 'ref_sample_id',
        "HMF_reg"           => 'submission',
        "SNP_required"      => 'is_snp_required',
        "SNP_exp"           => 'snp_experiment_id',
        "Requested_product" => 'request',
        "State"             => 'lab_status', # lab status
        "Primary_tumor_type"=> 'ptum',
        "Priority"          => 'priority',
        "Arival_date"       => 'arrival_date',
        "Remarks"           => 'remarks',
    );

    # Columns samples sheet in 2019 FOR-001
    my %SAMP_DICT_2019 = (
        "Sample_ID"           => 'sample_id',
        "Sample_name"         => 'sample_name',
        "DNA_conc"            => 'conc',
        "Yield"               => 'yield',
        "Q30"                 => 'q30',
        "Analysis_type"       => 'analysis_type',
        "Partner_sample"      => 'ref_sample_id',
        "HMF_reg"             => 'submission',
        "SNP_required"        => 'is_snp_required',
        "SNP_exp"             => 'snp_experiment_id',
        "Requested_product"   => 'request',
        "State"               => 'lab_status', # lab status
        "Priority"            => 'priority',
        "Arrival_date"        => 'arrival_date',
        "Remarks"             => 'remarks',
    );

    # Columns samples sheet 2020 FOR-001 is identical to 2019
    my %SAMP_DICT_2020 = %SAMP_DICT_2019;

    # Columns samples sheet CURRENT FOR-001 has extra ShallowSeq field
    my %SAMP_DICT = %SAMP_DICT_2020;
    $SAMP_DICT{"ShallowSeq_required"} = 'shallowseq';

    # Columns In Process sheet (HMF-FOR-002)
    my %PROC_DICT = (
        'Sample_ID'         => 'sample_id', # eg FR12345678
        'Sample_name'       => 'sample_name', # eg CPCT1234567R
        'Diluted_library'   => 'library_id', # eg FR12345678 (THIS WAS "barcode_3nm")
        'Sop_tracking_code' => 'lab_sop_versions',
    );

    my %lama_status_cohort_dict = (
        '_id'                  => 'cohort',
        'cohortCode'           => 'cohort_code',
        'reportPGX'            => 'report_pgx',
        'reportViral'          => 'report_viral',
        'reportGermline'       => 'report_germline',
        'flagGermlineOnReport' => 'flag_germline_on_report',
        'reportConclusion'     => 'report_conclusion',
        'isShallowStandard'    => 'shallowseq',
        'addToDatabase'        => 'add_to_database',
        'addToDatarequests'    => 'add_to_datarequests',
        'sendPatientReport'    => 'send_patient_report'
    );

    my %lama_patient_dict = (
        '_id' => 'patient',
        'hospitalPatientId' => 'hospital_patient_id'
    );

    my %lama_patient_tumor_sample_dict = (
        'legacySampleId'        => 'legacy_sample_name',
        'refFrBarcode'          => 'ref_sample_id',
        'hospitalPaSampleId'    => 'hospital_pa_sample_id',
        'patientGermlineChoice' => 'report_germline_level',
        'primaryTumorType'      => 'ptum',
        'biopsySite'            => 'biopsy_site',
        'sopVersion'            => 'blood_registration_sop',
        'collectionDate'        => 'sampling_date',
        'isCUP'                 => 'is_cup',
        'arrivalHmf'            => 'arrival_date',
        'submissionNr'          => 'submission',
    );

    my %lama_patient_blood_sample_dict = (
        'legacySampleId'  => 'legacy_sample_name',
        'sopVersion'      => 'blood_registration_sop',
        'collectionDate'  => 'sampling_date',
        'arrivalHmf'      => 'arrival_date',
        'sampleBarcode'   => 'sample_barcode',
        'submissionNr'    => 'submission',
        'originalBarcode' => 'original_barcode'
    );

    my %lama_isolation_isolate_dict = (
        '_id'           => 'original_container_id',
        'isolationNr'   => 'isolation_id',
        'coupeBarcode'  => 'coupes_barcode',
        'status'        => 'isolation_status',
        'type'          => 'isolation_type', # currently Blood|RNA|Tissue
        'concentration' => 'conc'
    );

    my %lama_libraryprep_library_dict = (
        'isShallowSeq' => 'shallowseq',
        'prepType'     => 'prep_type',
        'prepNr'       => 'prep_id',
        'status'       => 'prep_status'
    );

    my %lama_status_dict = (
        '_id'                  => 'received_sample_id',
        'prepStatus'           => 'lab_status',
        'registrationDateTime' => 'registration_date_epoch',
        'sampleId'             => 'sample_name',
        'frBarcodeDNA'         => 'sample_id_dna',
        'frBarcodeRNA'         => 'sample_id_rna',
        'isTissue'             => 'is_tissue',
        'shallowPurity'        => 'shallow_purity',
        'finalPurity'          => 'purity',
        'reportDate'           => 'report_date'
    );

    my %lama_content_translations_by_field_name = (
        'report_germline_level' => {
            'Yes: Only treatable findings' => '1: Behandelbare toevalsbevindingen',
            'Yes: All findings' => '2: Alle toevalsbevindingen',
            'No' => '2: No',
            'Yes' => '1: Yes'
        },
        'lab_status' => {
            'Processing' => 'In process',
        }
    );

    my %translations = (
        'CONT_CURR' => \%CONT_DICT,
        'SUBM_CURR' => \%SUBM_DICT,
        'SUBM_2020' => \%SUBM_DICT_2020,
        'SUBM_2019' => \%SUBM_DICT_2019,
        'SUBM_2018' => \%SUBM_DICT_2018,
        'SAMP_CURR' => \%SAMP_DICT,
        'SAMP_2020' => \%SAMP_DICT_2020,
        'SAMP_2019' => \%SAMP_DICT_2019,
        'SAMP_2018' => \%SAMP_DICT_2018,
        'PROC_CURR' => \%PROC_DICT,
        'lama_content_translations_by_field_name' => \%lama_content_translations_by_field_name,
        'lama_status_cohort_dict' => \%lama_status_cohort_dict,
        'lama_patient_dict' => \%lama_patient_dict,
        'lama_patient_tumor_sample_dict' => \%lama_patient_tumor_sample_dict,
        'lama_patient_blood_sample_dict' => \%lama_patient_blood_sample_dict,
        'lama_isolation_isolate_dict' => \%lama_isolation_isolate_dict,
        'lama_libraryprep_library_dict' => \%lama_libraryprep_library_dict,
        'lama_status_dict' => \%lama_status_dict,
    );

    return \%translations;
}
