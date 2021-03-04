import collections
from copy import deepcopy
from typing import Dict, Set, DefaultDict, FrozenSet, Tuple

from call_data import FullCall
from config.gene_info import GeneInfo
from config.haplotype import Haplotype
from config.panel import Panel
from config.variant import Variant


class HaplotypeCaller(object):
    @classmethod
    def get_gene_to_haplotypes_call(cls, full_calls: Tuple[FullCall, ...], panel: Panel) -> Dict[str, Set[str]]:
        gene_to_haplotype_calls = {}
        for gene_info in panel.get_gene_infos():
            print("[INFO] PROCESSING GENE " + gene_info.gene)
            gene_to_haplotype_calls[gene_info.gene] = cls.__get_haplotypes_call(full_calls, gene_info)
        return gene_to_haplotype_calls

    @classmethod
    def __get_haplotypes_call(cls, full_calls: Tuple[FullCall, ...], gene_info: GeneInfo) -> Set[str]:
        full_calls_for_gene = [call for call in full_calls if call.gene == gene_info.gene]
        try:
            variant_to_count: DefaultDict[Variant, int] = collections.defaultdict(int)
            for call in full_calls_for_gene:
                cls.__assert_handleable_call(call)
                rs_id = call.rs_ids[0]
                for annotated_allele in call.annotated_alleles:
                    if annotated_allele.is_variant_vs_grch38 is None:
                        error_msg = f"Unknown variant: allele={annotated_allele}"
                        raise ValueError(error_msg)
                    if annotated_allele.is_variant_vs_grch38:
                        variant_to_count[Variant(rs_id, annotated_allele.allele)] += 1
    
            explaining_haplotype_combinations = cls.__get_explaining_haplotype_combinations(
                variant_to_count, gene_info.haplotypes)
    
            if not explaining_haplotype_combinations:
                error_msg = f"No explaining haplotype combinations"
                raise ValueError(error_msg)
    
            minimal_explaining_haplotype_combination = cls.__get_minimal_haplotype_combination(
                explaining_haplotype_combinations)
    
            haplotype_to_count: DefaultDict[str, int] = collections.defaultdict(int)
            for haplotype in minimal_explaining_haplotype_combination:
                haplotype_to_count[haplotype] += 1
    
            haplotype_calls = set()
            for haplotype, count in haplotype_to_count.items():
                if count == 1:
                    haplotype_calls.add(haplotype + "_HET")
                elif count == 2:
                    haplotype_calls.add(haplotype + "_HOM")
                else:
                    error_msg = f"Impossible count for haplotype: haplotype={haplotype}, count={count}"
                    raise ValueError(error_msg)
    
            called_haplotypes_count = sum(haplotype_to_count.values())
    
            if called_haplotypes_count == 0:
                haplotype_calls.add(gene_info.reference_haplotype_name + "_HOM")
            elif called_haplotypes_count == 1:
                haplotype_calls.add(gene_info.reference_haplotype_name + "_HET")
    
            return haplotype_calls
    
        except ValueError as e:
            print(f"[Error] Cannot resolve haplotype for gene {gene_info.gene}. Error: {e}")
            return {"Unresolved_Haplotype"}

    @classmethod
    def __get_explaining_haplotype_combinations(
            cls, variant_to_count: DefaultDict[Variant, int], haplotypes: FrozenSet[Haplotype]) -> Set[Tuple[str, ...]]:
        """
        Gets combinations of haplotypes that explain all variants in the stated amounts. Uses recursion.
        Always makes sure that the haplotypes in a haplotype combination are ordered alphabetically to
        ensure that each haplotype combination exists only once in the result set.
        """
        if any(count < 0 for count in variant_to_count.values()):
            return set()
        if all(count == 0 for count in variant_to_count.values()):
            return {tuple()}
    
        result_set = set()
        for haplotype in haplotypes:
            reduced_variant_to_count = deepcopy(variant_to_count)
            for variant in haplotype.variants:
                reduced_variant_to_count[variant] -= 1
                
            combinations_for_reduced_variant_set = cls.__get_explaining_haplotype_combinations(
                reduced_variant_to_count, haplotypes
            )
            for combination in combinations_for_reduced_variant_set:
                result_set.add(tuple(sorted(list(combination) + [haplotype.name])))
    
        return result_set

    @classmethod
    def __get_minimal_haplotype_combination(
            cls, explaining_haplotype_combinations: Set[Tuple[str, ...]]) -> Tuple[str, ...]:
        min_haplotype_count = min(len(combination) for combination in explaining_haplotype_combinations)
        minimal_explaining_haplotype_combinations = {
            combination for combination in explaining_haplotype_combinations if len(combination) == min_haplotype_count
        }
        if len(minimal_explaining_haplotype_combinations) > 1:
            error_msg = (f"No unique minimal explaining haplotype combination: "
                         f"options={minimal_explaining_haplotype_combinations}")
            raise ValueError(error_msg)
        minimal_explaining_haplotype_combination = minimal_explaining_haplotype_combinations.pop()
        return minimal_explaining_haplotype_combination

    @classmethod
    def __assert_handleable_call(cls, call: FullCall) -> None:
        if len(call.rs_ids) > 1:
            error_msg = f"Call has more than one rs id: rs ids={call.rs_ids}, call={call}"
            raise ValueError(error_msg)
        if len(call.rs_ids) < 1:
            error_msg = f"Call has zero rs ids: call={call}"
            raise ValueError(error_msg)
        if call.rs_ids[0] == ".":
            error_msg = f"Call has unknown rs id: call={call}"
            raise ValueError(error_msg)
