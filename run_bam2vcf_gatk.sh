#!/bin/bash
#SBATCH -J sm
#SBATCH -o out
#SBATCH -e err
#SBATCH -p shared
#SBATCH -n 1
#SBATCH -t 6-23:00:00
#SBATCH --mem=50000


source ~/.conda/envs/snakemake/bin/activate
snakemake -n --snakefile Snakefile_bam2vcf_gatk --profile ./profiles/slurm

