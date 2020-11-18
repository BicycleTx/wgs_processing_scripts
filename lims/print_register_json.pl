#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use File::Basename;
use Getopt::Long;
use File::Slurp;
use Time::Piece;
use JSON;
use 5.010.000;

my $DATETIME = localtime;
my $SCRIPT = basename $0;
my $OUT_SEP = "\t";
my $NA_CHAR = "NA";

my $GER_INI = "SingleSample.ini";
my $SOM_INI = "Somatic.ini";
my $SHA_INI = "ShallowSeq.ini";

my $Q30_LIM = 75; # q30 limit is currently fixed for all CPCT/DRUP samples
my $YIELD_F = 1e9; # LAB lims contains yield in Gbase not base

## could make these more fine grained (lower number is higher prio)
my $NO_PIPELINE_PRIO = 100;
my $YES_PIPELINE_PRIO = 99;

my $LIMS_IN_FILE = '/data/ops/lims/prod/lims.json';
my $JSON_BASE_DIR = '/data/ops/api/prod/jsons';
my $JSON_DONE_DIR = '/data/ops/api/prod/jsons/registered';
my $SHALLOW_RUNS_DIR = '/data/data_archive/shallow_seq_pipelines';
my $USE_EXISTING_REF = 0;
my $USE_EXISTING_TUM = 0;
my $FORCE_OUTPUT = 0;

## -----
## Gather input
## -----
my %opt = ();
GetOptions (
  "samplesheet=s"  => \$opt{ samplesheet },
  "outdir=s"       => \$JSON_BASE_DIR,
  "donedir=s"      => \$JSON_DONE_DIR,
  "limsjson=s"     => \$LIMS_IN_FILE,
  "useExistingRef" => \$USE_EXISTING_REF,
  "useExistingTum" => \$USE_EXISTING_TUM,
  "forceOutput"    => \$FORCE_OUTPUT,
  "debug"          => \$opt{ debug },
  "help|h"         => \$opt{ help },
  "verbose"        => \$opt{ verbose }
) or die "Error in command line arguments\n";
my @ids = @ARGV;

my $HELP =<<HELP;

  Description
    Parses LIMS JSON file and writes JSON(s) to perform 
    registering in HMF API. It does check whether the to be
    written JSON already exists in either the output location
    or the "register done" location.
    
    Done location: $JSON_DONE_DIR
    
  Usage
    $SCRIPT -samplesheet \${samplesheetpath}
      eg: $SCRIPT -samplesheet /data/run/SampleSheet.csv
    
    $SCRIPT \${sample_id} [\${sample_id2} \${sample_id_n}]
      eg: $SCRIPT FR12345678
      eg: $SCRIPT FR11111111 FR22222222 FR33333333
    
  Options
    -outdir <string>   [$JSON_BASE_DIR]
    -limsjson <string> [$LIMS_IN_FILE] 
    -useExistingRef    (add use_existing_sample flag for ref sample in json)
    -useExistingTum    (add use_existing_sample flag for tum sample in json)
    -forceOutput       (write json even if sample already has run in $JSON_DONE_DIR)

HELP

print $HELP and exit(0) if $opt{ help };
print $HELP and exit(0) if scalar(@ids) == 0 and not defined $opt{ samplesheet };
die "[ERROR] JSON output dir is not writeable ($JSON_BASE_DIR)?\n" unless -w $JSON_BASE_DIR;

## -----
## MAIN
## -----
say "[INFO] START of script $SCRIPT";
say "[INFO] DateTime: $DATETIME";

if ( defined $opt{ samplesheet } ){
  say "[INFO] Reading SampleSheet file ($opt{ samplesheet })";
  my $ids_from_sheet = addSamplesFromSamplesheet( $opt{ samplesheet } );
  push( @ids, @$ids_from_sheet );
}

say "[INFO] InputCount: ".scalar(@ids);
say "[INFO] Reading LIMS file ($LIMS_IN_FILE)";
my $lims = readJson( $LIMS_IN_FILE );
my $samples = $lims->{ 'samples' };
my %stats = ();
my @msg = ();
my $existingJsons = listExistingJsons($JSON_BASE_DIR, $JSON_DONE_DIR);

foreach my $sample_id ( @ids ){
    say "[INFO] Processing $sample_id";
    my $return = processSample( $sample_id, $samples, \%stats );
    $stats{ $return }++;
}

say "[STAT] -----";

foreach my $reason ( keys %stats ){
    my $count = $stats{ $reason };
    say "[STAT]   $reason = $count";
}

## -----
## /MAIN
## -----
    
sub addSamplesFromSamplesheet{
    my ($file) = @_;
    
    my %head = ();
    my %data = ();
    my $currblock = '';
    
    ## first read file to obtain header fields
    my @header;
    open my $header_fh, '<', $file or die "Unable to open file ($file): $!\n";
    while ( <$header_fh> ){
        chomp;
        if ( $_ =~ /^\[Data\]/ ){
            my $header_line = <$header_fh>;
            die "[ERROR] Header line should contain Sample_ID\n" unless $header_line =~ /Sample_ID/;
            @header = split( ",", $header_line );
        }
    }
    close $header_fh;
    die "[ERROR] No header line was parsed?\n" unless scalar @header;
    
    ## re-read file to get all information
    open my $samplesheet_fh, '<', $file or die "Unable to open file ($file): $!\n";
    while ( <$samplesheet_fh> ){
        chomp;
        next if $_ eq '' or $_ =~ /^[\,\s]+$/;
        if ( $_ =~ /^\[(Header|Reads|Settings|Data)\]/ ){
            $currblock = $1;
        }
        elsif ( $currblock eq 'Header' ){
            my ($field, $content) = split /\,/;
            $head{ $field } = $content;
        }
        elsif ( $currblock eq 'Data' ){
            next if $_ =~ /Sample_ID/; # skip data header line
            my @line_values = split( ',', $_ );
            my %record = ();
            foreach my $field ( @header ){
                $record{ $field } = shift @line_values;
            }
            my $id = $record{ 'Sample_ID' };
            my $name = $record{ 'Sample_Name' };
            my $submission = $record{ 'Sample_Project' };
            if ( $submission eq "HMFregVAL" or $submission eq "HMFregGIAB" ){
                warn "[WARN] SKIPPING sample ($name, $id) because of unsupported submission in SampleSheet ($submission)\n";
                next();
            }
            $data{ $id } = 1;
        }
    }
    close $samplesheet_fh;
    
    my $hmfRunName = $head{ 'ExperimentName' } || $NA_CHAR;
    say "[INFO] Found run $hmfRunName in SampleSheet";
    my @out = sort keys %data;
    return( \@out );
}

sub processSample{
    my ($sample_id, $lims, $stats) = @_;
    my @warn_msg = ();
    if ( not exists $lims->{ $sample_id } ){
        warn "[WARN]   RESULT: Sample not present in LIMS ($sample_id)\n";
        return "NoJsonMade_sampleDoesNotExistsInLims";
    }
    my $sample = $lims->{ $sample_id };
    
    my $name       = getValueByKey( $sample, 'sample_name' ); # eg CPCT02010000R
    my $barcode    = getValueByKey( $sample, 'sample_id' ); # eg FR12345678
    my $patient    = getValueByKey( $sample, 'patient' ); # eg CPCT02010000
    my $submission = getValueByKey( $sample, 'submission' ); # eg HMFregCPCT
    my $analysis   = getValueByKey( $sample, 'analysis_type' ); # eg Somatic_T
    my $entity     = getValueByKey( $sample, 'entity' ); # eg HMFreg0001
    my $label      = getValueByKey( $sample, 'label' ); # eg CPCT
    my $priority   = getPriority( $sample );
    my $yield      = getValueByKey( $sample, 'yield' ) * $YIELD_F;
    
    ## reset 0 yield to 1 base in order to avoid samples being ready directly
    ## except for so-called "VirtualSample" samples (these index seqs should be absent)
    if ( $yield == 0 and $name !~ /^VirtualSample\d+/ ){
        $yield = 1;
    }
    
    my $use_existing_ref = $USE_EXISTING_REF;
    my $use_existing_tum = $USE_EXISTING_TUM;

    ## not all samples have q30 field because this was added later to lims
    my $q30 = $Q30_LIM;
    if ( defined $sample->{ 'q30' } ){
        $q30 = $sample->{ 'q30' };
    }
    if ( $q30 !~ /^\d+$/ or $q30 < 0 or $q30 > 100 ){
        die "[ERROR] Q30 found for sample ($name) but not an integer percentage ($q30)\n";
    }
    
    ## init the json info
    my %json_data = ();
    
    say "[INFO]   NAME=$name, ENTITY=$entity, ANALYSIS:$analysis";

    my $date = localtime->strftime('%y%m%d');

    ## fill json based on analysis type
    if ( $analysis eq 'RnaAnalysis' ){
        warn "[WARN]   RESULT: Type $analysis not yet supported\n";
        return "NoJsonMade_rnaTypeNotSupported";
    }
    elsif ( $analysis eq 'BCL' ){
        warn "[WARN]   RESULT: Type $analysis not yet supported\n";
        return "NoJsonMade_bclTypeNotSupported";
    }
    elsif ( $analysis eq 'FASTQ' ){
        my $set = join("_", $date, $submission, $barcode, $name );
        say "[INFO]   SET: $set";
        $json_data{ 'set_name' } = "$set";
        $json_data{ 'entity' } = "$entity";

        $json_data{ 'fastq_portal' } = JSON::true;
        addSampleToJsonData( \%json_data, $submission, $barcode, $name, 'ref', $q30, $yield, $use_existing_ref );
    }
    elsif( $analysis eq 'SingleAnalysis' ){
        my $set = join( "_", $date, $submission, $barcode, $name );
        say "[INFO]   SET: $set";
        $json_data{ 'ini' } = "$GER_INI";
        $json_data{ 'set_name' } = "$set";
        $json_data{ 'entity' } = "$entity";
        addSampleToJsonData( \%json_data, $submission, $barcode, $name, 'ref', $q30, $yield, $use_existing_ref );
    }
    elsif ( $analysis eq 'Somatic_T' ){
        
        my $ref_obj;
        my $ini = $SOM_INI;
        my $needs_shallow = getValueByKey( $sample, 'shallowseq' ); # 0 | 1
        my $other_ref = getValueByKey( $sample, 'other_ref' ); # Yes | No
        
        ## need to find the ref sample of somatic pair
        if ( exists $sample->{ ref_sample_id } and $sample->{ ref_sample_id } ne "" ){
            ## for somatic samples (biopsy) a ref sample needs to be defined
            my $ref_sample_id = $sample->{ ref_sample_id };
            $ref_obj = getSomaticRSampleByStringForField( $lims, $ref_sample_id, 'sample_id' );
        }
        else{
            ## fallback for for CPCT etc the partner can be found by patient name + R
            my $ref_string = $patient.'R';
            $ref_obj = getSomaticRSampleByStringForField( $lims, $ref_string, 'sample_name' );
        }

        if ( not defined $ref_obj ){
            warn "[WARN]   RESULT: SKIPPING because somatic R not found for input T (PATIENT=$patient)\n";
            return "NoJsonMade_RnotFoundForSomaticT";
        }
        
        my $barcode_ref = getValueByKey( $ref_obj, 'sample_id' );
        my $name_ref = getValueByKey( $ref_obj, 'sample_name' );
        my $yield_ref = getValueByKey( $ref_obj, 'yield' );
        my $submission_ref = getValueByKey( $ref_obj, 'submission' );
        $yield_ref = $yield_ref == 0 ? 1 : $yield_ref * $YIELD_F;
        my $set = join( "_", $date, $submission, $barcode_ref, $barcode, $patient );

        ## adjust content in case of ShallowSeq
        if ( $needs_shallow ){
            say "[INFO]   ShallowSeq flag set in LIMS";
            my $match_string = join( "_", "ShallowSeq", $barcode_ref, $barcode, $name );
            my $status_query = "query_api.pl -type runs -filter \"ini=ShallowSeq.ini\" -filter \"name=$match_string\" -json | jq -r '.[-1].status'";
            my $run_status = `$status_query`;
            my $dir_exists = `find $SHALLOW_RUNS_DIR -maxdepth 1 -type d -name "*$match_string" | wc -l`;
            my $jsn_exists = `find $JSON_DONE_DIR -maxdepth 1 -type f -name "*$match_string.json" | wc -l`;

            chomp($run_status);
            chomp($dir_exists);
            chomp($jsn_exists);
            
            if ( $run_status eq "Waiting" ){
                warn "[WARN]   RESULT: SKIPPING because run found for $match_string with status $run_status (so assuming extra seq)\n";
                return "NoJsonMade_ShallowExtraSeq";
            }
            elsif ( $dir_exists ){
                say "[INFO]   ShallowSeq run dir found locally for $match_string: going for full Somatic mode";
            }
            elsif ( $jsn_exists ){
                say "[INFO]   ShallowSeq json found for $match_string: going for full Somatic mode";
            }
            else{
                say "[INFO]   No ShallowSeq run/json found yet for $match_string: going for ShallowSeq mode";
                $yield = 35 * $YIELD_F;
                $yield_ref = $yield;
                $entity = 'HMF_SHALLOWSEQ';
                $set = join( "_", $date, "ShallowSeq", $barcode_ref, $barcode, $name );
                $ini = $SHA_INI;
                $priority = $YES_PIPELINE_PRIO;
           }
        }

        ## add suffix to ref barcode if ref needed from other patientId
        if ( $other_ref eq "Yes" ){
            my $new_barcode_ref = $barcode_ref . "_" . $name;
            push( @warn_msg, "DOUBLE CHECK JSON for $barcode ($name): OtherRef flag is set in LIMS so adding suffix to the REF barcode ($new_barcode_ref)" );
            $barcode_ref = $new_barcode_ref;
        }
 
        ## check if barcode already exists in HMF API
        my $tum_exists = `query_api.pl -type samples -filter "barcode=$barcode" -exact | grep -v Unregistered | grep -cv ^#`;
        chomp($tum_exists);
        my $ref_exists = `query_api.pl -type samples -filter "barcode=$barcode_ref" -exact | grep -v Unregistered | grep -cv ^#`;
        chomp($ref_exists);
        
        if ( $tum_exists ){
            push( @warn_msg, "TUM barcode ($barcode) for sample ($name) already exists in HMF API (so use_existing flag was added!)" );
            $use_existing_tum = 1;
        }        
        if ( $ref_exists ){
            push( @warn_msg, "REF barcode ($barcode_ref) for sample ($name) already exists in HMF API (so use_existing flag was added!)" );
            $use_existing_ref = 1;
        }
        
        say "[INFO]   SET: $set";
        $json_data{ 'ini' } = "$ini";
        $json_data{ 'set_name' } = "$set";
        $json_data{ 'entity' } = "$entity";
        $json_data{ 'priority' } = $priority;
        addSampleToJsonData( \%json_data, $submission_ref, $barcode_ref, $name_ref, 'ref', $q30, $yield_ref, $use_existing_ref );
        addSampleToJsonData( \%json_data, $submission, $barcode, $name, 'tumor', $q30, $yield, $use_existing_tum );
    }
    elsif ( $analysis eq 'Somatic_R' ){
        say "[INFO]   RESULT for $sample_id: SKIPPING because is somatic ref sample ($name)";
        return "NoJsonMade_isSomaticR";
    }
    else{
        warn "[WARN]   RESULT for $sample_id: Somehow no (correct) analysis type ($analysis) was defined for input\n";
        return "NoJsonMade_hasWrongAnalsisType";
    }

    ## output json
    my $json_file = $json_data{ 'set_name' }.'.json';
    my $json_path = $JSON_BASE_DIR.'/'.$json_file;
    
    ## check if set was already registered earlier
    my $setname_wo_date = $json_data{ 'set_name' };
    $setname_wo_date =~ s/^\d{6}_//;
    my @base_jsons = glob( "$JSON_BASE_DIR/*json" );
    my @done_jsons = glob( "$JSON_DONE_DIR/*json" );
    
    foreach my $existing_json ( @base_jsons, @done_jsons ){
        if ( $existing_json =~ /$setname_wo_date/ ){
            if ( $FORCE_OUTPUT ){
                push( @warn_msg, "Existing run for $sample_id ($existing_json) but output json enforced" );
            }
            else{
                warn "[WARN]   RESULT for $sample_id ($name): SKIPPING because set json exists ($existing_json)\n";
                return "NoJsonMade_setJsonAlreadyExists";
            }
        }
    }
    
    ## print any stored warnings now
    if ( scalar @warn_msg ){
        foreach my $msg ( @warn_msg ){
            warn "[WARN]   $msg\n";
        }
    }
    
    ## all checks were OK: print config file
    printSetJson( \%json_data, $json_path );
    say "[INFO]   RESULT for $sample_id: OK";
    return "OK_JSON_MADE";
}

sub listExistingJsons{
    my @source_dirs = @_;
    my @jsons = ();
    foreach my $dir ( @source_dirs ){
        push( @jsons, glob( "$dir/*json" ) );
    }
    return \@jsons;
}

sub printSetJson{
    my ($data, $out_path) = @_;
    my $json_obj = JSON->new->allow_nonref;
    my $json_txt = $json_obj->pretty->encode( $data );
    say "[INFO]   Writing json ($out_path)";
    open OUT, '>', $out_path or die "Unable to open output file ($out_path): $!\n";
        print OUT $json_txt;
    close OUT;
}

sub readJson{
    my ($json_file) = @_;
    my $json_txt = read_file( $json_file );
    my $json_obj = decode_json( $json_txt );
    return( $json_obj );
}

sub getSomaticRSampleByStringForField{
    my ($info, $search_string, $search_field) = @_;
    
    foreach my $sample_id ( keys %$info ){
        my $field_value = $info->{ $sample_id }{ $search_field };
        if (( $field_value eq $search_string ) and ( $info->{ $sample_id }{ 'analysis_type' } eq 'Somatic_R')){
            return $info->{ $sample_id };
        }
    }
    warn "[WARN] $search_string not found in field $search_field of any record\n";
    return(undef);
}

sub getValueByKey{
    my ($info, $key) = @_;
    if ( not defined $info->{ $key } ){
        say "[ERROR] Cannot find field \"$key\" in data structure:";
        print Dumper( $info );
        die "[ERROR] Unable to get field $key\n"
    }
    else{
        return( $info->{ $key } );
    }
}

sub getPriority{
    my ($info, $key) = @_;
    ## unfortunately cannot err on key absence 
    ## because not all samples have the prio property
    if ( defined $info->{ 'priority' } and $info->{ 'priority' } =~ /yes/i ){
        return $YES_PIPELINE_PRIO;
    }
    else{
        return $NO_PIPELINE_PRIO;
    }
}

sub addEntityToJsonData{
    my ($json_data, $submission, $patient, $dict1, $dict2) = @_;
    
    ## CPCT and DRUP are continues: create entity by centerid
    if ( $patient =~ m/^(CPCT|DRUP|WIDE)(\d{2})(\d{2})(\d{4})$/ ){
        my ( $umbrella_study, $study_id, $center_id, $patient_id ) = ( $1, $2, $3, $4 );
        if ( exists $dict1->{$center_id} ){
            my $center_name = $dict1->{$center_id};
            $json_data->{ 'entity' } = $umbrella_study."_".$center_name;
        }
        else{
            die "[ERROR] center id not found in hash ($center_id)\n";
        }
    }
    ## otherwise entity must have been set by LAB team in $SUBMISSION_TO_ENTITY_FILE
    elsif( exists $dict2->{$submission} ){
        my $entity = $dict2->{$submission};
        $json_data->{ 'entity' } = $entity;
    }
    ## no entity found: should not happen
    else{
        die "[ERROR] entity not found for submission ($submission) of patient ($patient)\n";
    }
}

sub addSampleToJsonData{
    my ($store, $submission, $barcode, $name, $type, $q30, $yield, $use_existing) = @_;
    my %tmp = (
        'barcode'    => "$barcode",
        'name'       => "$name",
        'submission' => "$submission",
        'type'       => "$type",
        'q30_req'    => int($q30),
        'yld_req'    => int($yield),
    );
    if ( $use_existing ){
        $tmp{ 'use_existing_sample' } = JSON::true;
    }
    push( @{$store->{ 'samples' }}, \%tmp );
}

