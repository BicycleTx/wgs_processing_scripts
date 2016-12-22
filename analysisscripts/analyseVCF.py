#!/usr/local/bin/python
import pandas as pd
import difflib as dl
import chromosomeDefinition as cd

###############################################
# VCF CONFIG
VCF_SAMPLE = "CPCT11111111"
VCF_PATH = "/Users/peterpriestley/hmf/analyses/70-30sample/160524/"
VCF_FILE_NAME = VCF_SAMPLE + "R_" + VCF_SAMPLE + "T_merged_somatics.vcf"
SAMPLE_NAMES = {VCF_SAMPLE + 'T.mutect': 'mutect',
                VCF_SAMPLE + 'T.freebayes': 'freebayes',
                'TUMOR.strelka': 'strelka',
                'TUMOR.varscan': 'varscan'}


###############################################

class variantType:
    def __init__(self):
        pass

    sameAsRef = "Same as Ref"
    missingGenotype = "Missing Genotype"
    indel = "INDEL"
    SNP = "SNP"
    mixed = "MIXED"


class subVariantType:
    def __init__(self):
        pass

    none = ""
    insert = "INSERT"
    delete = "DELETE"
    indel = "INDEL"


def indelDiff(ref, variantAllele):
    # LOGIC - MATCH 1st char and then use strDiff in the reverse direction
    if ref[0] == variantAllele[0]:
        i = 1
    else:
        i = 0
    reverseRef = ref[i:][::-1]
    reverseVariantAllele = variantAllele[i:][::-1]
    strdiff = dl.SequenceMatcher(None, reverseRef, reverseVariantAllele)
    myIndelString = ""
    for item in strdiff.get_opcodes():
        if item[0] == 'delete':
            myIndelString = myIndelString + "-" + reverseRef[item[1]:item[2]]
        elif item[0] == 'insert':
            myIndelString = myIndelString + "+" + reverseVariantAllele[item[3]:item[4]]
    myIndelString = myIndelString[::-1]
    # Find IndelPOs
    # if len(variantAllele)>len(ref):
    #    myRelativePos = variantAllele[i:].find(myIndelString)- i
    # elif len(ref)>len(variantAllele):
    #    myRelativePos = ref[i:].find(myIndelString) - i
    # else:
    #    myRelativePos = -1

    return myIndelString


def calculateReadDepth(format, genotype):
    formatSplit = format.split(':')
    genotypeSplit = genotype.split(':')
    if 'DP' in formatSplit:
        try:
            return int(genotypeSplit[formatSplit.index('DP')])
        except IndexError:
            return -1
        except ValueError:
            return -1
    else:
        return 1


def calculateNumCallers(infoSplit, infoHeaders, internalCount):
    if "CSP" in infoHeaders:
        return int(infoSplit[infoHeaders.index("CSP")].split('=')[1])
    elif "CC" in infoHeaders:
        return int(infoSplit[infoHeaders.index("CC")].split('=')[1])
    else:
        return internalCount


def calculateSomaticGenotype(infoSplit, infoHeaders, caller, aVariantType):
    # Ideally both Normal (ref, hom, het) and somatic (ref,hom,het).
    if caller == 'strelka' and aVariantType == variantType.indel:
        return infoSplit[infoHeaders.index("SGT")].split('=')[1]
    elif caller == 'strelka' and aVariantType == variantType.SNP:
        return infoSplit[infoHeaders.index("NT")].split('=')[1]
    elif caller == 'varscan':  # VARSCAN - 'SS=1,2,3,4' germline,somatic,LOH, unknown
        return infoSplit[infoHeaders.index("SS")].split('=')[1]
    elif caller == 'freebayes' and 'VT' in infoHeaders:  # FREEBAYES - Better would be GT(Normal)  0/0 = ref;  X/X = het;  X/Y = hom;
        return infoSplit[infoHeaders.index("VT")].split('=')[1]
    elif caller == 'mutect':  # Mutect is always het ?
        return "ref-het"
    else:
        return 'unknown'


def calculateQualityScore(infoSplit, infoHeaders, caller, qual, aVariantType):
    if caller == 'strelka' and aVariantType == variantType.indel:
        try:
            return infoSplit[infoHeaders.index("QSI_NT")].split('=')[1]
        except ValueError:
            return -1
    elif caller == 'strelka' and aVariantType == variantType.SNP:
        return infoSplit[infoHeaders.index("QSS_NT")].split('=')[1]
    elif caller == 'varscan':
        if "VS_SSC" in infoHeaders:
            return infoSplit[infoHeaders.index("VS_SSC")].split('=')[1]
        else:
            return infoSplit[infoHeaders.index("SSC")].split('=')[1]
    elif caller == 'freebayes':
        return qual
    elif caller == 'Set1GIAB12878':
        try:
            return infoSplit[infoHeaders.index("MQ")].split('=')[1]
        except ValueError:
            return -1
    else:  # Mutect has no quality score
        return -1


def calculateConsensusVariantType(tumorCallerCountSNP, tumorCallerCountIndel, tumorCallerCountSubTypeDelete,
                                  tumorCallerCountSubTypeInsert, tumorCallerCountSubTypeIndel):
    if tumorCallerCountIndel > 0 and tumorCallerCountSNP > 0:
        return variantType.mixed, ""
    elif tumorCallerCountIndel > 0:
        if tumorCallerCountSubTypeDelete > 0 and tumorCallerCountSubTypeIndel == 0 and tumorCallerCountSubTypeInsert == 0:
            return variantType.indel, subVariantType.delete
        elif tumorCallerCountSubTypeInsert > 0 and tumorCallerCountSubTypeIndel == 0 and tumorCallerCountSubTypeDelete == 0:
            return variantType.indel, subVariantType.insert
        else:
            return variantType.indel, subVariantType.indel
    elif tumorCallerCountSNP > 0:
        return variantType.SNP, ""
    else:
        return variantType.missingGenotype, ""


def calculateAllelicFreq(format, genotype, caller, tumorVariantType, ref, alleleTumor2):
    formatSplit = format.split(':')
    genotypeSplit = genotype.split(':')

    if caller == 'mutect':
        return float(genotypeSplit[formatSplit.index('FA')])
    elif caller == 'varscan':
        return float(genotypeSplit[formatSplit.index('FREQ')].split('%')[0]) / 100
    else:
        if caller == 'freebayes':
            ao_split = genotypeSplit[formatSplit.index('AO')].split(',')
            ad = ao_split[min(int(genotype[2]), len(ao_split)) - 1]  # NB - Assume B if GT = A/B
            rd = genotypeSplit[formatSplit.index('RO')].split(',')[0]
        elif caller == 'strelka' and tumorVariantType == variantType.SNP:
            ad = genotypeSplit[formatSplit.index(alleleTumor2 + 'U')].split(',')[0]  # NB - Assume B if GT = A/B
            rd = genotypeSplit[formatSplit.index(ref + 'U')].split(',')[0]
        elif caller == 'strelka' and tumorVariantType == variantType.indel:
            ad = genotypeSplit[formatSplit.index('TIR')].split(',')[0]
            rd = genotypeSplit[formatSplit.index('TAR')].split(',')[0]
        else:
            try:
                rd, ad = genotypeSplit[formatSplit.index('AD')].split(',')[:2]
            except ValueError:
                return -1
        if float(ad) == 0:
            return 0
        else:
            return float(ad) / (float(rd) + float(ad))  # is this correct, or should it be /DP?


class genotype:
    def __init__(self, caller, ref, alt, qual, infoSplit, infoHeaders, format, inputGenotype):
        altsplit = (ref + "," + alt).split(',')
        self.tumorVariantSubType = subVariantType.none
        alleleTumor2 = ""
        if inputGenotype[:3] == "./.":
            self.tumorVariantType = variantType.missingGenotype
        elif inputGenotype[:3] == "0/0" or alt == ".":  # STRELKA unfiltered
            self.tumorVariantType = variantType.sameAsRef
        else:
            if inputGenotype[1] != '/':  # STRELKA unfiltered case
                alleleTumor1 = altsplit[1]
                alleleTumor2 = altsplit[1]
            else:
                alleleTumor1 = altsplit[int(inputGenotype[0])]
                alleleTumor2 = altsplit[int(inputGenotype[2])]
            if len(alleleTumor1) == len(alleleTumor2) and len(alleleTumor1) == len(ref):
                self.tumorVariantType = variantType.SNP
            else:
                self.tumorVariantType = variantType.indel
                if len(alleleTumor1) <= len(ref) and len(alleleTumor2) <= len(ref):
                    self.tumorVariantSubType = subVariantType.delete
                elif len(alleleTumor1) >= len(ref) and len(alleleTumor2) >= len(ref):
                    self.tumorVariantSubType = subVariantType.insert
                else:
                    self.tumorVariantSubType = subVariantType.indel

            self.allele = alleleTumor2
            self.indelDiff = indelDiff(ref, self.allele)

            self.allelicFreq = calculateAllelicFreq(format, inputGenotype, caller, self.tumorVariantType, ref,
                                                    alleleTumor2)
            self.readDepth = calculateReadDepth(format, inputGenotype)
            self.qualityScore = float(
                calculateQualityScore(infoSplit, infoHeaders, caller, qual, self.tumorVariantType))
            self.somaticGenotype = calculateSomaticGenotype(infoSplit, infoHeaders, caller, self.tumorVariantType)
            if self.somaticGenotype == 'unknown':
                self.somaticGenotype = inputGenotype[:3]


class somaticVariant:
    variantInfo = []
    bedItem = []

    def __init__(self, chrom, pos, id, ref, alt, qual, filter, info, format, inputGenotypes, useFilter, useBed,
                 aBedReverse, loadRegionsOutsideBed):

        # Find the 1st Bed region with maxPos > variantPos
        if aBedReverse:
            if not somaticVariant.bedItem:
                somaticVariant.bedItem = aBedReverse.pop()
            while cd.intChrom(chrom) > cd.intChrom(somaticVariant.bedItem[0]) or (
                    cd.intChrom(chrom) == cd.intChrom(somaticVariant.bedItem[0]) and int(pos) > int(
                    somaticVariant.bedItem[2])) and aBedReverse:
                somaticVariant.bedItem = aBedReverse.pop()
        else:
            somaticVariant.bedItem = []

        # Label the BED region
        bedRegion = ""
        if (somaticVariant.bedItem and int(somaticVariant.bedItem[1]) <= int(pos) and int(
                somaticVariant.bedItem[2]) >= int(pos) and somaticVariant.bedItem[0] == chrom):
            try:
                bedRegion = somaticVariant.bedItem[3]
            except IndexError:
                bedRegion = "Default"

        # Process if in Bed region or not using BED or if loading whole file
        if bedRegion <> "" or not useBed or loadRegionsOutsideBed:
            if filter == "PASS" or filter == "." or useFilter == False:

                tumorCallerCountSNP = 0
                tumorCallerCountIndel = 0
                tumorCallerCountSubTypeIndel = 0
                tumorCallerCountSubTypeDelete = 0
                tumorCallerCountSubTypeInsert = 0
                variantGenotypes = {}

                # Split info fields
                infoSplit = info.split(';')
                infoHeaders = [x.split('=')[0] for x in infoSplit]

                # CALLER SPECIFIC FIELDS
                for key in inputGenotypes.iterkeys():
                    variantGenotypes[key] = genotype(key, ref, alt, qual, infoSplit, infoHeaders, format,
                                                     inputGenotypes[key])

                # CALLER COUNTS
                for key, value in variantGenotypes.items():
                    if value.tumorVariantType == variantType.SNP:
                        tumorCallerCountSNP += 1
                    if value.tumorVariantType == variantType.indel:
                        tumorCallerCountIndel += 1
                        if value.tumorVariantSubType == subVariantType.delete:
                            tumorCallerCountSubTypeDelete += 1
                        if value.tumorVariantSubType == subVariantType.insert:
                            tumorCallerCountSubTypeInsert += 1
                        if value.tumorVariantSubType == subVariantType.indel:
                            tumorCallerCountSubTypeIndel += 1

                # META DATA
                if "set" in infoHeaders:
                    vennSegment = infoSplit[infoHeaders.index("set")].split('=')[1]
                else:
                    vennSegment = "test"  # to do - calculate somatic, LOH, or germline
                numCallers = calculateNumCallers(infoSplit, infoHeaders, tumorCallerCountSNP + tumorCallerCountIndel)
                if "filter" in vennSegment:
                    numCallers = numCallers - 1
                myVariantType, mySubVariantType = calculateConsensusVariantType(tumorCallerCountSNP,
                                                                                tumorCallerCountIndel,
                                                                                tumorCallerCountSubTypeDelete,
                                                                                tumorCallerCountSubTypeInsert,
                                                                                tumorCallerCountSubTypeIndel)
                inDBSNP = any(['rs' in x for x in id.split(';')])
                inCOSMIC = any(['COSM' in x for x in id.split(';')])

                # ANNOTATIONS
                annWorstEffect = ""
                annAllEffects = ""
                annWorstImpact = ""
                annGene = ""
                if 'ANN' in infoHeaders:
                    annSplit = infoSplit[infoHeaders.index("ANN")].split('=')[1].split(',')
                    annWorstImpact = annSplit[0].split('|')[2]
                    annWorstEffect = annSplit[0].split('|')[1]
                    annAllEffects = '|'.join([annAllEffects + x.split('|')[1] for x in annSplit])
                    annGene = annSplit[0].split('|')[3]

                # CONSENSUS RULE
                consensus = int(numCallers) >= 3 or (
                int(numCallers) == 2 and bedRegion <> "" and (not inDBSNP or inCOSMIC))

                ############### Pandas Prep ####################
                # APPEND NORMAL FIELDS
                somaticVariant.variantInfo.append(
                    [chrom, pos, chrom + ':' + pos, cd.intChrom(chrom) + float(pos) / cd.chromosomeLength[chrom], id,
                     ref, vennSegment, numCallers,
                     myVariantType, mySubVariantType, filter, bedRegion, inDBSNP, inCOSMIC, annGene, annWorstImpact,
                     annWorstEffect, annAllEffects, consensus])

                # APPEND CALLER SPECIFIC FIELDS
                for caller, variantGenotype in variantGenotypes.items():
                    if variantGenotype.tumorVariantType == variantType.indel or variantGenotype.tumorVariantType == variantType.SNP:
                        callerSpecificFields = [variantGenotype.allele, variantGenotype.allelicFreq,
                                                variantGenotype.readDepth,
                                                variantGenotype.qualityScore, variantGenotype.somaticGenotype,
                                                variantGenotype.indelDiff]
                    else:
                        callerSpecificFields = ['', '', '', '', '', '']
                    somaticVariant.variantInfo[-1] = somaticVariant.variantInfo[-1] + callerSpecificFields
                    #########################################


def loadVariantsFromVCF(aPath, aVCFFile, sampleNames, aPatientName, useFilter, useBed=False, aBed=None,
                        loadRegionsOutsideBed=False):
    if aBed is None:
        aBed = []
    variants = []
    i = 0

    if useBed:
        aBed.reverse()

    print "reading vcf file:", aVCFFile
    with open(aPath + aVCFFile, 'r') as f:
        header_index = {}
        for line in f:

            line = line.strip('\n')
            a = [x for x in line.split('\t')]

            if a[0] == '#CHROM':
                headers = a[9:]
                for sampleName, sampleLabel in sampleNames.iteritems():
                    for index, header in enumerate(headers):
                        if sampleName == header:
                            header_index[sampleLabel] = index
                            break
                    if not header_index.has_key(sampleLabel):
                        print 'Error - missing sample input: ', sampleLabel
                        return -1

            if a[0][:1] != '#':
                variant_calls = a[9:]
                myGenotypes = {}
                for caller, index in header_index.iteritems():
                    myGenotypes[caller] = variant_calls[index]
                variants.append(
                    somaticVariant(a[0].lstrip("chr"), a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], myGenotypes,
                                   useFilter, useBed, aBed, loadRegionsOutsideBed))
                i += 1
                if i % 100000 == 0:
                    print "reading VCF File line:", i

    # Reset bed item
    somaticVariant.bedItem = []

    print "Number variants loaded:", len(somaticVariant.variantInfo)

    ###### PANDAS ##############
    df = pd.DataFrame(somaticVariant.variantInfo)
    if len(df) > 0:
        myColumnList = ['chrom', 'pos', 'chromPos', 'chromFrac', 'id', 'ref', 'vennSegment', 'numCallers',
                        'variantType', 'variantSubType', 'filter',
                        'bedRegion', 'inDBSNP', 'inCOSMIC', 'annGene', 'annWorstImpact', 'annWorstEffect',
                        'annAllEffects', 'consensus']
        for caller in header_index.iterkeys():
            myColumnList = myColumnList + [caller + 'allele', caller + 'AF', caller + 'DP', caller + 'QS',
                                           caller + 'SGT', caller + 'indelDiff']
        df.columns = (myColumnList)
        df['patientName'] = aPatientName
    ###### END PANDAS ###########

    # Need to empty genotype.variantInfo in case we need to load multiple files
    del somaticVariant.variantInfo[:]
    return df


def loadBEDFile(aPath, aBEDFile):
    myBed = []
    with open(aPath + aBEDFile, 'r') as f:
        for line in f:
            line = line.strip('\n')
            line = line.strip('\r')
            splitLine = line.split('\t')
            if splitLine[0] != 'chrom':
                myBed.append(splitLine)
    return myBed


def printStatistics(df):
    # Calculate 2+_caller precision and sensitivity
    outputdata = []
    for columnName in list(df):
        if columnName.endswith('allele'):
            myCaller = columnName[:-6]
            variantTypes = df[(df[myCaller + 'allele'] != '')].variantType.unique()
            for variantType in variantTypes:
                truePositives = len(
                    df[(df[myCaller + 'allele'] != '') & (df['numCallers'] >= 2) & (df['variantType'] == variantType)])
                falseNegatives = len(
                    df[(df[myCaller + 'allele'] == '') & (df['numCallers'] >= 2) & (df['variantType'] == variantType)])
                positives = len(df[(df[myCaller + 'allele'] != '') & (df['variantType'] == variantType)])
                truthSet = truePositives + falseNegatives
                if positives > 0:
                    outputdata.append(
                        [variantType, myCaller, truthSet, truePositives, positives - truePositives, falseNegatives,
                         round(truePositives / float(positives), 4), round(truePositives / float(truthSet), 4)])

    outputDF = pd.DataFrame(outputdata)
    outputDF.columns = (['variantType', 'caller', 'truthSet', 'truePositives', 'falsePositives', 'falseNegatives',
                         'precision_2+_callers', 'sensitivity_2+_callers'])
    print '\n2+ caller precision and sensitivity\n'
    print outputDF.sort_values(['variantType', 'caller'])

    # calculate # of variants by variant type
    print '\n# of variants by sub type\n'
    print df[['pos', 'variantSubType']].groupby(['variantSubType']).agg('count')

    # calculate # of callers
    print '\n# of variants by number of callers and variant type\n'
    df_pivot = df[['numCallers', 'pos', 'variantType']].groupby(['variantType', 'numCallers']).agg('count')
    print df_pivot.groupby(level=0).transform(lambda x: x / x.sum())

    df = loadVariantsFromVCF(VCF_PATH, VCF_FILE_NAME, SAMPLE_NAMES, True, VCF_SAMPLE, False)
    printStatistics(df)


def poolOfNormals(fileandSampleNames):
    for fileandSampleName in fileandSampleNames:
        with open(fileandSampleName[0], 'r') as f:
            header_index = {}
            for line in f:

                line = line.strip('\n')
                a = [x for x in line.split('\t')]

                if a[0] == '#CHROM':
                    try:
                        header_index = a[9:].index(fileandSampleName[1])
                    except IndexError:
                        print 'Error - missing sample input: ', fileandSampleName[1]
                        return -1

                if a[0][:1] != '#':
                    myGenotypes = {}
                    myGenotypes['GATK'] = a[9:][header_index]
                    somaticVariant(a[0].lstrip("chr"), a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], myGenotypes,
                                   False, False, "", True)

            # for variant in somaticVariant.variantInfo:
            from collections import Counter
            myDict = Counter([(x[0], x[1], x[5], x[8], x[19]) for x in somaticVariant.variantInfo])
            # print myDict


            myDict2 = {k: v for k, v in myDict.iteritems() if v > 1}
            print len(myDict2)

            import csv
            with open('/Users/peterpriestley/Documents/dict.csv', 'wb') as csv_file:
                writer = csv.writer(csv_file)
                for key, value in myDict.items():
                    writer.writerow([key[0], key[1], key[2], key[3], key[4], value])

# mylist=[['/Users/peterpriestley/hmf/analyses/ensembleRuleTesting/160922_HMFregCPCT_FR10302782_FR12251860_CPCT02060023.filtered_variants_snpEff_snpSift_Cosmicv76_GoNLv5_sliced.vcf','CPCT02060023R']]
# mylist=[['/Users/peterpriestley/hmf/analyses/2016SEP-OCTTestRuns/160922_GIABDIFF_NA12878_NA12878_NA12878.filtered_variants.vcf','12878R'],['/Users/peterpriestley/hmf/analyses/2016SEP-OCTTestRuns/160922_GIABDIFF_NA12878_NA12878_NA12878.filtered_variants.vcf','12878T']]
# poolOfNormals(mylist)
