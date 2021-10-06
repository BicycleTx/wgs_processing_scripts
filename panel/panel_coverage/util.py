from concurrent.futures import ProcessPoolExecutor
from copy import deepcopy
from pathlib import Path
from typing import Set, Dict

from genome import Interval


class CoverageInfo(object):
    def __init__(self, interval_to_cumulative_coverage: Dict[Interval, int],
                 min_coverage_to_interval_to_count_with_min_coverage: Dict[int, Dict[Interval, int]]) -> None:
        self.__interval_to_cumulative_coverage = deepcopy(interval_to_cumulative_coverage)
        self.__interval_to_count_with_min_coverage = deepcopy(min_coverage_to_interval_to_count_with_min_coverage)

    def get_cumulative_coverage(self, interval: Interval) -> int:
        return self.__interval_to_cumulative_coverage[interval]

    def get_count_with_min_coverage(self, interval: Interval, min_coverage: int) -> int:
        return self.__interval_to_count_with_min_coverage[min_coverage][interval]


def parallel_get_sample_to_coverage_info(
        sample_to_depth_file: Dict[str, Path],
        intervals: Set[Interval],
        min_coverage: int
) -> Dict[str, CoverageInfo]:
    print("Before coverage_info process pool")
    with ProcessPoolExecutor() as executor:
        sample_to_future = {
            sample: executor.submit(get_coverage_info, depth_file, intervals, min_coverage)
            for sample, depth_file in sample_to_depth_file.items()
        }
        sample_to_coverage_info = {
            sample: future.result()
            for sample, future in sample_to_future.items()
        }
    print("After coverage_info process pool")
    return sample_to_coverage_info


def get_coverage_info(
        depth_file: Path, intervals: Set[Interval], min_coverage: int) -> CoverageInfo:
    try:
        chrom_to_position_to_intervals = get_chrom_to_position_to_overlapping_intervals(intervals)

        interval_to_cumulative_coverage = {interval: 0 for interval in intervals}
        interval_to_count_with_min_coverage = {interval: 0 for interval in intervals}
        with open(depth_file) as depth_f:
            for line in depth_f:
                chromosome, position_str, coverage_str = line.split("\t")
                coverage = int(coverage_str)
                position = int(position_str)
                if coverage >= min_coverage:
                    for interval in chrom_to_position_to_intervals.get(chromosome, {}).get(position, []):
                        interval_to_count_with_min_coverage[interval] += 1
                for interval in chrom_to_position_to_intervals.get(chromosome, {}).get(position, []):
                    interval_to_cumulative_coverage[interval] += coverage

        return CoverageInfo(interval_to_cumulative_coverage, {min_coverage: interval_to_count_with_min_coverage})
    except Exception as e:
        error_msg = f"Error for {depth_file}: {e}"
        raise ValueError(error_msg)


def get_chrom_to_position_to_overlapping_intervals(intervals: Set[Interval]) -> Dict[str, Dict[int, Set[Interval]]]:
    chrom_to_position_to_exons: Dict[str, Dict[int, Set[Interval]]] = {}
    for interval in intervals:
        if interval.chromosome not in chrom_to_position_to_exons.keys():
            chrom_to_position_to_exons[interval.chromosome] = {}
        for position in range(interval.start_position, interval.end_position + 1):
            if position not in chrom_to_position_to_exons[interval.chromosome]:
                chrom_to_position_to_exons[interval.chromosome][position] = set()
            chrom_to_position_to_exons[interval.chromosome][position].add(interval)
    return chrom_to_position_to_exons


def assert_file_exists(path: Path) -> None:
    if not path.exists():
        raise FileNotFoundError(f"File not found: {path}")
