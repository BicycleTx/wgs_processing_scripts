from typing import NamedTuple, Dict, List, Collection, Set

from base.gene_coordinate import GeneCoordinate
from base.json_alias import Json
from base.util import get_key_to_multiple_values, get_covered_coordinates


class RsIdInfo(NamedTuple):
    rs_id: str
    reference_allele_grch37: str
    reference_allele_grch38: str
    start_coordinate_grch37: GeneCoordinate
    start_coordinate_grch38: GeneCoordinate

    @classmethod
    def from_json(cls, data: Json) -> "RsIdInfo":
        rs_id = str(data['rsid'])
        reference_allele_grch37 = str(data['referenceAllele'])
        reference_allele_grch38 = str(data['referenceAlleleGRCh38'])
        start_coordinate_grch37 = GeneCoordinate(str(data['chromosome']), int(data['position']))
        start_coordinate_grch38 = GeneCoordinate(str(data['chromosome']), int(data['positionGRCh38']))
        info = RsIdInfo(
            rs_id,
            reference_allele_grch37,
            reference_allele_grch38,
            start_coordinate_grch37,
            start_coordinate_grch38,
        )
        return info

    def is_compatible(self, other: "RsIdInfo") -> bool:
        if self.rs_id == other.rs_id:
            return self == other
        else:
            return (
                not self.get_relevant_grch37_coordinates().intersection(other.get_relevant_grch37_coordinates())
                and not self.get_relevant_grch38_coordinates().intersection(other.get_relevant_grch38_coordinates())
            )

    def get_relevant_grch37_coordinates(self) -> Set[GeneCoordinate]:
        return get_covered_coordinates(self.start_coordinate_grch37, self.reference_allele_grch37)

    def get_relevant_grch38_coordinates(self) -> Set[GeneCoordinate]:
        return get_covered_coordinates(self.start_coordinate_grch38, self.reference_allele_grch38)


def assert_no_overlap_rs_ids(infos: Collection[RsIdInfo], source_name: str) -> None:
    if rs_ids_overlap(infos):
        rs_id_to_multiple_infos = get_rs_id_to_multiple_infos(infos)
        error_msg = (
            f"The {source_name} contains rs id summaries with the same rs id but different positions. "
            f"Duplicates: {rs_id_to_multiple_infos}"
        )
        raise ValueError(error_msg)


def rs_ids_overlap(infos: Collection[RsIdInfo]) -> bool:
    return len({info.rs_id for info in infos}) != len(infos)


def get_rs_id_to_multiple_infos(infos: Collection[RsIdInfo]) -> Dict[str, List[RsIdInfo]]:
    return get_key_to_multiple_values([(info.rs_id, info) for info in infos])
