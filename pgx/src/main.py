import argparse
import json
import os
import subprocess
import sys
from shutil import copyfile
from typing import List, Dict, Any, Set, Tuple

import allel
import pandas as pd

from base.gene_coordinate import GeneCoordinate
from call_data import Grch37Call, Grch37CallData
from config.panel import Panel
from pgx_analysis import PgxAnalyser


def main(vcf: str, sample_t_id: str, sample_r_id: str, version: str, panel_path: str, outputdir: str,
         recreate_bed: bool, vcftools: str, sourcedir: str) -> None:
    """ Run pharmacogenomics analysis on sample """
    print("\n[INFO] ## START PHARMACOGENOMICS ANALYSIS")

    # Check if output dir exists, create if it does not
    if not os.path.exists(outputdir):
        try:
            os.makedirs(outputdir)
        except FileExistsError:
            # Directory already exists
            pass

    # Get configuration
    panel = load_panel(panel_path)
    bed_file = get_bed_file(panel_path, recreate_bed, panel, sourcedir)

    if panel.is_empty():
        sys.exit("[ERROR] No panel is given, so no analysis can be performed.")

    # Get data for patient
    filtered_vcf = get_filtered_vcf(vcf, bed_file, sample_r_id, sample_t_id, outputdir, vcftools)
    call_data = get_call_data(filtered_vcf, panel)

    # Compute output from input data
    gene_to_haplotype_calls, panel_calls_for_patient_df = PgxAnalyser.create_pgx_analysis(call_data, panel)

    # Output
    out = outputdir + "/" + sample_t_id
    print_calls_to_file(panel_calls_for_patient_df, out + "_calls.txt")
    print_haplotypes_to_file(gene_to_haplotype_calls, out + "_genotype.txt", panel, panel_path, version)
    # Also copy the bed-filtered VCF file for research purposes
    copyfile(filtered_vcf, out + "_PGx.vcf")

    # Clean up
    if os.path.exists(filtered_vcf):
        if os.path.exists(filtered_vcf):
            os.remove(filtered_vcf)
            print("[INFO] " + filtered_vcf + " removed.")
        if os.path.exists(filtered_vcf.replace(".recode.vcf", ".log")):
            os.remove(filtered_vcf.replace(".recode.vcf", ".log"))
            print("[INFO] " + filtered_vcf.replace(".recode.vcf", ".log") + " removed.")

    # TODO: add genes CYP2D6, CYP3A4, CYP3A5

    print("[INFO] ## PHARMACOGENOMICS ANALYSIS FINISHED\n")


def get_call_data(filtered_vcf: str, panel: Panel) -> Grch37CallData:
    variants = get_variants_from_filtered_vcf(filtered_vcf)
    return get_call_data_from_variants(variants, panel)


def get_call_data_from_variants(variants: Dict[str, Any], panel: Panel) -> Grch37CallData:
    match_on_rsid = 0
    match_on_location = 0
    filtered_calls = []
    for i, rs_ids_string in enumerate(variants['variants/ID']):
        chromosome = str(variants['variants/CHROM'][i])
        position = int(variants['variants/POS'][i])
        reference_allele = str(variants['variants/REF'][i])

        rs_ids = get_rs_ids_from_string(rs_ids_string)
        relevant_coordinates = get_relevant_coordinates(chromosome, position, reference_allele)

        rs_id_match_to_panel_exists = any(panel.contains_rs_id(rs_id) for rs_id in rs_ids)
        coordinate_match_to_panel_exists = any(
            panel.contains_rs_id_with_grch37_coordinate(coord) for coord in relevant_coordinates
        )
        if rs_id_match_to_panel_exists or coordinate_match_to_panel_exists:
            if rs_id_match_to_panel_exists:
                match_on_rsid += 1
            if coordinate_match_to_panel_exists:
                match_on_location += 1
            if variants['variants/FILTER_PASS'][i]:
                filter_type = "PASS"
            else:
                filter_type = "FILTERED"
            alts = [str(allele) for allele in variants['variants/ALT'][i]]
            variant_annotation = str(variants['variants/ANN_HGVS_c'][i])
            gene = str(variants['variants/ANN_Gene_Name'][i])
            genotype = variants['calldata/GT'][i][0].tolist()
            if genotype == [0, 1]:
                alleles = (reference_allele, alts[0])
            elif genotype == [1, 1]:
                alleles = (alts[0], alts[0])
            elif genotype == [1, 2]:
                alleles = (alts[0], alts[1])
            elif genotype == [0, 0]:
                alleles = (reference_allele, reference_allele)
                variant_annotation = "REF_CALL"
            else:
                error_msg = f"[ERROR] Genotype not found: {genotype}"
                raise ValueError(error_msg)

            call = Grch37Call(
                GeneCoordinate(chromosome, position),
                reference_allele,
                alleles,
                gene,
                rs_ids,
                variant_annotation,
                filter_type
            )
            filtered_calls.append(call)

    print("[INFO] Matches on RS id: " + str(match_on_rsid))
    print("[INFO] Matches on location: " + str(match_on_location))

    return Grch37CallData(tuple(filtered_calls))


def get_rs_ids_from_string(rs_ids_string: str) -> Tuple[str, ...]:
    if ";" in rs_ids_string:
        return tuple(str(rs) for rs in rs_ids_string.split(";") if rs.startswith("rs"))
    else:
        return (str(rs_ids_string),)


def get_relevant_coordinates(chromosome: str, position: int, ref_allele: str) -> Tuple[GeneCoordinate, ...]:
    return tuple(GeneCoordinate(chromosome, position + i) for i in range(len(ref_allele)))


def get_variants_from_filtered_vcf(filtered_vcf: str) -> Dict[str, Any]:
    try:
        field_names = ['samples', 'calldata/GT', 'variants/ALT', 'variants/CHROM', 'variants/FILTER', 'variants/ID', 
                       'variants/POS', 'variants/QUAL', 'variants/REF', 'variants/ANN']
        variants = allel.read_vcf(filtered_vcf, fields=field_names, transformers=allel.ANNTransformer())
    except IOError:
        sys.exit("[ERROR] File " + filtered_vcf + " not found or cannot be opened.")
    return variants


def get_filtered_vcf(vcf: str, bed_file: str, sample_r_id: str, sample_t_id: str, outputdir: str, vcftools: str) -> str:
    filtered_vcf_prefix = outputdir + '/' + sample_t_id + '_PGx'
    filtered_vcf = filtered_vcf_prefix + '.recode.vcf'
    # Check if output vcf does not already exist
    if os.path.exists(filtered_vcf):
        raise IOError("Temporary VCF file " + filtered_vcf + " already exists. Exiting.")

    subprocess.run([vcftools, '--gzvcf', vcf, '--bed', bed_file, '--out', filtered_vcf_prefix,
                    '--indv', sample_r_id, '--recode', '--recode-INFO-all'])
    print("[INFO] Subprocess completed.")
    return filtered_vcf


def load_panel(panel_path: str) -> Panel:
    """ Load manually annotated JSON panel file """
    try:
        with open(panel_path, 'r+', encoding='utf-8') as json_file:
            data = json.load(json_file)
            return Panel.from_json(data)
    except IOError:
        sys.exit(f"[ERROR] Panel file {panel_path} not found or cannot be opened.")


def get_bed_file(panel_path: str, recreate_bed: bool, panel: Panel, sourcedir: str) -> str:
    bed_file = replace_file_extension_of_path(panel_path, "bed")
    if recreate_bed:
        create_bed_file(panel.get_genes(), panel_path, sourcedir, bed_file)
    if not os.path.exists(bed_file):
        sys.exit(
            "[ERROR] Could not locate bed-file. "
            "Could it be that it should be (re)created? "
            "Retry running with --recreate_bed."
        )
    return bed_file


def create_bed_file(genes_in_panel: Set[str], panel_path: str, sourcedir: str, bed_path: str) -> None:
    """ Generate bed file from gene panel and save as panel_path.bed """
    print("[INFO] Recreating bed-file...")
    header = 'track name="' + panel_path + '" description="Bed file generated from ' + panel_path + \
             ' with HMF_PGx main.py"\n'
    bed_regions = []  # chrom, start, end, gene
    covered = []
    transcripts = open(sourcedir + "/all_genes.37.tsv", 'r')
    for line in transcripts:
        split_line = line.rstrip().split("\t")
        if split_line[4] in genes_in_panel and split_line[4] not in covered:
            bed_regions.append([split_line[0], split_line[1], split_line[2], split_line[4]])
            covered.append(split_line[4])
    if set(covered) != genes_in_panel:
        raise ValueError("[ERROR] Missing genes from the gene panel in the transcript list. Please check:\nCovered:\n"
                         + str(covered) + "\nOriginal gene panel:\n" + str(genes_in_panel))

    with open(bed_path, 'w') as bed:
        bed.write(header)
        for entry in bed_regions:
            bed.write("\t".join(entry) + "\n")

    print("[INFO] Created " + bed_path)


def print_calls_to_file(panel_calls_for_patient_df: pd.DataFrame, calls_file: str) -> None:
    panel_calls_for_patient_df.to_csv(calls_file, sep='\t', index=False)


def print_haplotypes_to_file(gene_to_haplotype_calls: Dict[str, Set[str]], genotype_file: str, panel: Panel,
                             panel_path: str, version: str) -> None:
    # TODO: make this more clean.
    gene_to_haplotype_to_severity = {}
    for gene_info in panel.get_gene_infos():
        haplotype_to_severity = {
            gene_info.reference_haplotype_name: "Normal Function",
            'Unresolved': "Unknown Function"
        }
        for haplotype in gene_info.haplotypes:
            haplotype_to_severity[haplotype.name] = haplotype.function

        gene_to_haplotype_to_severity[gene_info.gene] = haplotype_to_severity

    gene_to_drug_info = {}
    for gene_info in panel.get_gene_infos():
        sorted_drugs = sorted(
            [drug for drug in gene_info.drugs],
            key=lambda info: (info.name, info.url_prescription_info)
        )
        gene_to_drug_info[gene_info.gene] = [
            ";".join([drug.name for drug in sorted_drugs]),
            ";".join([drug.url_prescription_info for drug in sorted_drugs])
        ]

    with open(genotype_file, 'w') as f:
        f.write("gene\thaplotype\tfunction\tlinked_drugs\turl_prescription_info\tpanel_version\trepo_version\n")
        for gene in sorted(list(gene_to_haplotype_calls.keys())):
            for haplotype_call in sorted(list(gene_to_haplotype_calls[gene])):
                f.write(
                    gene + "\t" +
                    haplotype_call + "\t" +
                    gene_to_haplotype_to_severity[gene][haplotype_call.split("_")[0]] + "\t" +
                    gene_to_drug_info[gene][0] + "\t" +
                    gene_to_drug_info[gene][1] + "\t" +
                    panel_path + "\t" +
                    version + "\n"
                )


def parse_args(sys_args: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=('Run pharmacogenomics panel on germline VCF file. The pharmacogenomic annotations are done on '
                     'GRCh38, so in the output both reference genome output is given where possible.')
    )
    parser.add_argument('vcf', type=str, help='VCF file to use for pharmacogenomics analysis')
    parser.add_argument('sample_t_id', type=str, help='The sample ID of the tumor')
    parser.add_argument('sample_r_id', type=str, help='The sample ID of the normal')
    parser.add_argument('version', type=str, help='The version of the tool')
    parser.add_argument('outputdir', type=str, help='Directory to store output of pharmacogenomic analysis')
    parser.add_argument('panel', type=str, help='Json file with the panel variants')
    parser.add_argument('vcftools', type=str, default='vcftools', help="Path to vcftools > 0.1.14 if not in $PATH")
    parser.add_argument(
        '--recreate_bed', default=False, action='store_true',
        help='Recreate bed-file from JSON files. If false, the panel file with extension .bed is searched for.'
    )
    parser.add_argument('--sourcedir', type=str, default='data', help="Optional path to location of source files")
    return parser.parse_args(sys_args)


def replace_file_extension_of_path(path: str, new_file_extension: str) -> str:
    split_path = path.split(".")
    new_path = ".".join(split_path[0:-1]) + "." + new_file_extension
    return new_path


if __name__ == '__main__':
    args = parse_args(sys.argv[1:])
    main(args.vcf, args.sample_t_id, args.sample_r_id, args.version, args.panel,
         args.outputdir, args.recreate_bed, args.vcftools, args.sourcedir)
