localrules: mkDBmapfile

rule bam2gvcf:
    """
    This rule scatters analyses over two dimensions: sample name and list file. For each BAM file, one per sample,
    a GVCF is created for all the scaffolds present in a given list file.
    """
    input:
        ref = config['ref'],
        fai = config['ref'] + ".fai",
        dict = refBaseName + ".dict",
        bam = bamDir + "{sample}" + bam_suffix,
        l = intDir + "gatkLists/list{list}.list"
    output: 
        gvcf = gvcfDir + "{sample}/{sample}_L{list}.raw.g.vcf.gz",
        gvcf_idx = gvcfDir + "{sample}/{sample}_L{list}.raw.g.vcf.gz.tbi",
        doneFile = touch(gvcfDir + "{sample}/{sample}_L{list}.done")
    resources: 
        #!The -Xmx value the tool is run with should be less than the total amount of physical memory available by at least a few GB
        # subtract that memory here
        mem_mb = lambda wildcards, attempt: attempt * res_config['bam2gvcf']['mem'],   # this is the overall memory requested
        time = lambda wildcards, attempt: attempt * res_config['bam2gvcf']['time'],
        reduced = lambda wildcards, attempt: attempt * (res_config['bam2gvcf']['mem'] - 500)  # this is the maximum amount given to java
    params:
        minPrun = config['minP'],
        minDang = config['minD']
    conda:
        "../envs/bam2vcf.yml"
    shell:
        "gatk HaplotypeCaller "
        "--java-options \"-Xmx{resources.reduced}m\" "
        "-R {input.ref} "
        "-I {input.bam} "
        "-O {output.gvcf} "
        "-L {input.l} "
        "--emit-ref-confidence GVCF --min-pruning {params.minPrun} --min-dangling-branch-length {params.minDang}"

rule mkDBmapfile:
    """
    This rule makes DB map files for the GenomicsDBImport function. These files contain the names of all the samples for a particular
    list. This can be necessary because with many samples (thousands) the gatk command can get too long if you include all sample
    names on the command line, so long SLURM throws an error.
    """
    input:
        # NOTE: the double curly brackets around 'list' prevent the expand function from operating on that variable
        # thus, we expand by sample but not by list, such that we gather by sample for each list value
        gvcfs = expand(gvcfDir + "{sampleDir}/{sampleFile}_L{{list}}.raw.g.vcf.gz", zip, sampleFile=SAMPLES, sampleDir=SAMPLES),
        gvcfs_idx = expand(gvcfDir + "{sampleDir}/{sampleFile}_L{{list}}.raw.g.vcf.gz.tbi", zip, sampleFile=SAMPLES, sampleDir=SAMPLES),
        doneFiles = expand(gvcfDir + "{sampleDir}/{sampleFile}_L{{list}}.done", zip, sampleFile=SAMPLES, sampleDir=SAMPLES)
    output:
        dbMapFile = dbDir + "DB_mapfile_L{list}"
    params:
        # to use wildcards in 'run' statement below, specify them here
        l = "{list}"
    run:
        fileName = dbDir + f"DB_mapfile_L{params.l}"
        f=open(fileName, 'w') 
        for s in SAMPLES:
            print(s, gvcfDir + s + "/" + s + f"_L{params.l}.raw.g.vcf.gz", sep="\t", file=f)  
        f.close() 

rule gvcf2DB:
    """
    This rule gathers results for a given list file name, so the workflow is now scattered in only a single dimension. 
    Here we take many gvcfs for a particular list of scaffolds and combine them into a GenomicsDB.
    Samples are thus gathered by a shared list name, but lists are still scattered.
    """
    input:
        l = intDir + "gatkLists/list{list}.list",
        dbMapFile = dbDir + "DB_mapfile_L{list}"
    output: 
        DB = directory(dbDir + "DB_L{list}"),
        doneFile = temp(touch(dbDir + "DB_L{list}.done"))
    resources: 
        mem_mb = lambda wildcards, attempt: attempt * res_config['gvcf2DB']['mem'],   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * (res_config['gvcf2DB']['mem'] - 3000)  # this is the maximum amount given to java
    conda:
        "../envs/bam2vcf.yml"
    shell:
        # NOTE: reader-threads > 1 useless if you specify multiple intervals
        # a forum suggested TILEDB_DISABLE_FILE_LOCKING=1 to remedy sluggish performance
        "export TILEDB_DISABLE_FILE_LOCKING=1 \n"
        "gatk GenomicsDBImport "
        "--java-options \"-Xmx{resources.reduced}m -Xms{resources.reduced}m\" "
        "--genomicsdb-workspace-path {output.DB} "
        "-L {input.l} "
        "--tmp-dir {dbDir}tmp "
        "--sample-name-map {input.dbMapFile} \n"

rule DB2vcf:
    """
    This rule uses the genomic databases from the previous step (gvcf2DB) to create VCF files, one per list file. Thus, lists
    are still scattered.
    """
    input:
        DB = dbDir + "DB_L{list}",
        ref = config['ref'],
        doneFile = dbDir + "DB_L{list}.done"
    output: 
        vcf = vcfDir + "L{list}.vcf"
    resources: 
        mem_mb = lambda wildcards, attempt: attempt * res_config['DB2vcf']['mem'],   # this is the overall memory requested
        reduced = lambda wildcards, attempt: attempt * (res_config['DB2vcf']['mem'] - 3000)  # this is the maximum amount given to java
    conda:
        "../envs/bam2vcf.yml"
    shell:
        "gatk GenotypeGVCFs "
        "--java-options \"-Xmx{resources.reduced}m -Xms{resources.reduced}m\" "
        "-R {input.ref} "
        "-V gendb://{input.DB} "
        "-O {output.vcf} "
        "--tmp-dir {vcfDir}tmp"

rule gatherVcfs:
    """
    This rule filters all of the VCFs, then gathers, one per list, into one final VCF
    """
    input:
        vcfs = expand(vcfDir + "L{list}.vcf", list=LISTS),
        ref = config['ref']
    output: 
        vcfs = expand(vcfDir + "L{list}_filter.vcf", list=LISTS),
        vcfFinal = config["gatkDir"] + config['spp'] + "_final.vcf.gz"
    params:
        gatherVcfsInput = helperFun.getVcfs_gatk(LISTS, vcfDir)
    conda:
        "../envs/bam2vcf.yml"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * res_config['gatherVcfs']['mem']   # this is the overall memory requested
    shell:
        "gatk VariantFiltration "
        "-R {input.ref} "
        "-V {input.vcfs} " 
        "--output {output.vcfs} "
        "--filter-name \"RPRS_filter\" "
        "--filter-expression \"(vc.isSNP() && (vc.hasAttribute('ReadPosRankSum') && ReadPosRankSum < -8.0)) || ((vc.isIndel() || vc.isMixed()) && (vc.hasAttribute('ReadPosRankSum') && ReadPosRankSum < -20.0)) || (vc.hasAttribute('QD') && QD < 2.0)\" "
        "--filter-name \"FS_SOR_filter\" "
        "--filter-expression \"(vc.isSNP() && ((vc.hasAttribute('FS') && FS > 60.0) || (vc.hasAttribute('SOR') &&  SOR > 3.0))) || ((vc.isIndel() || vc.isMixed()) && ((vc.hasAttribute('FS') && FS > 200.0) || (vc.hasAttribute('SOR') &&  SOR > 10.0)))\" "
        "--filter-name \"MQ_filter\" "
        "--filter-expression \"vc.isSNP() && ((vc.hasAttribute('MQ') && MQ < 40.0) || (vc.hasAttribute('MQRankSum') && MQRankSum < -12.5))\" "
        "--filter-name \"QUAL_filter\" "
        "--filter-expression \"QUAL < 30.0\" "
        "--invalidate-previous-filters true\n"
        
        "gatk GatherVcfs "
        "{params.gatherVcfsInput} "
        "-O {output.vcfFinal}"

rule vcftools:
    input:
        vcf = config["gatkDir"] + config['spp'] + "_final.vcf.gz",
        int = intDir + "intervals_fb.bed"
    output: 
        missing = gatkDir + "missing_data_per_ind.txt",
        SNPsPerInt = gatkDir + "SNP_per_interval.txt"
    conda:
        "../envs/bam2vcf.yml"
    resources:
        mem_mb = lambda wildcards, attempt: attempt * res_config['vcftools']['mem']    # this is the overall memory requested
    shell:
        "vcftools --gzvcf {input.vcf} --remove-filtered-all --minDP 1 --stdout --missing-indv > {output.missing}\n"
        "bedtools intersect -a {input.int} -b {input.vcf} -c > {output.SNPsPerInt}"
