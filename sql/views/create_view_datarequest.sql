CREATE OR REPLACE VIEW datarequest AS

SELECT
	clinical.*, purity AS tumorPurity, qcStatus AS purpleQC, fitMethod AS purpleFitMethod,
	version AS purpleVersion, metric.sufficientCoverage AS sufficientCoverage
FROM
	clinical
	INNER JOIN purity ON purity.sampleId = clinical.sampleId
	INNER JOIN metric ON metric.sampleId = clinical.sampleId
WHERE
	blacklisted = 0 AND qcStatus = 'PASS' AND sufficientCoverage = 1 AND fitMethod <> 'NO_TUMOR' AND purity > 0.195 AND
	(clinical.sampleId LIKE '%CPCT%' OR clinical.sampleId LIKE '%WIDE%' OR clinical.sampleId LIKE '%DRUP%');
