SELECT * FROM germlineVariant2
WHERE (
(pathogenic = 'UNANNOTATED' AND canonicalCodingEffect IN ('NONSENSE_OR_FRAMESHIFT','SPLICE') AND reported = 0)						                    #also check for filter here
OR (pathogenic IN ('CLINVAR_PATHOGENIC','CLINVAR_LIKELY_PATHOGENIC','WHITE_LIST') AND reported = 0)
OR (pathogenic = 'CLINVAR_CONFLICTING' AND filter = 'PASS')
OR (gene IN ('BMPR1A','EPCAM','FH','FLCN','POLD1','SDHA','SDHAF2','SDHB','SDHC','SDHD') AND biallelic = 0 AND reported = 1)			#these genes are not in gene panel AND require biallelic reporting. We should check somaticVariant in case the WT allele is not already lost.
OR (gene IN ('NTHL1','MUTYH') AND reported = 1 AND germlineGenotype = 'HOM')                                                                                   #these genes should only be marked with patient notification in case of refStatus = homozygous
OR (gene IN ('CDK4','RET','MET','KIT') AND reported = 1 AND pathogenic = 'UNANNOTATED' AND canonicalCodingEffect IN ('NONSENSE_OR_FRAMESHIFT','SPLICE'))
OR (sampleId IN (SELECT sampleId FROM germlineVariant WHERE gene = 'MUTYH' AND reported = 1 GROUP BY sampleId HAVING count(sampleId)>1))
OR (sampleId IN (SELECT sampleId FROM germlineVariant WHERE gene = 'NTHL1' AND reported = 1 GROUP BY sampleId HAVING count(sampleId)>1)))
AND sampleId IN ("COREDB010034T","COREDB010039T","CORELR020039T","CORELR110013T","CORELR110017T","DRUP01070178T","WIDE01011233T");
