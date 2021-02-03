from copy import deepcopy
from typing import List, Set

from gene_info import GeneInfo, assert_no_overlap_gene_names
from json_alias import Json
from rs_id_info import RsIdInfo, assert_no_overlap_rs_ids


class Panel(object):
    def __init__(self, gene_infos: List[GeneInfo], rs_id_infos: Set[RsIdInfo]) -> None:
        assert_no_overlap_rs_ids(rs_id_infos, "panel json")
        assert_no_overlap_gene_names(gene_infos, "panel json")

        self.__gene_infos = deepcopy(gene_infos)
        self.__rs_id_infos = deepcopy(rs_id_infos)

    def __eq__(self, other: object) -> bool:
        return (
            isinstance(other, Panel)
            and self.__gene_infos == other.__gene_infos
            and self.__rs_id_infos == other.__rs_id_infos
        )

    def __repr__(self) -> str:
        return (
            f"Panel("
            f"gene_infos={self.__gene_infos}, "
            f"rs_id_infos={self.__rs_id_infos}, "
            f")"
        )

    @classmethod
    def from_json(cls, data: Json) -> "Panel":
        gene_infos = [GeneInfo.from_json(gene_info_json) for gene_info_json in data['genes']]
        rs_id_infos = {rs_id_info for gene_info in gene_infos for rs_id_info in gene_info.variants}
        return Panel(gene_infos, rs_id_infos)

    def get_gene_infos(self) -> List[GeneInfo]:
        return deepcopy(self.__gene_infos)

    def get_rs_id_infos(self) -> Set[RsIdInfo]:
        return deepcopy(self.__rs_id_infos)

    def contains_rs_id_with_position(self, position_string: str) -> bool:
        for info in self.__rs_id_infos:
            if info.start_coordinate_grch37.matches_position_string(position_string):
                return True
        return False

    def get_rs_id_with_position(self, position_string: str) -> str:
        matching_rs_ids = []
        for info in self.__rs_id_infos:
            if info.start_coordinate_grch37.matches_position_string(position_string):
                matching_rs_ids.append(info.rs_id)

        if matching_rs_ids and len(matching_rs_ids) == 1:
            return matching_rs_ids.pop()
        elif not matching_rs_ids:
            raise ValueError("No rs ids match position")
        else:
            raise ValueError("Multiple rs ids match position")

    def contains_rs_id(self, rs_id: str) -> bool:
        return rs_id in self.get_rs_ids()

    def get_rs_ids(self) -> Set[str]:
        return {info.rs_id for info in self.__rs_id_infos}

    def is_empty(self) -> bool:
        return not self.__gene_infos and not self.__rs_id_infos

    def get_genes(self) -> List[str]:
        return [info.gene for info in self.__gene_infos]
