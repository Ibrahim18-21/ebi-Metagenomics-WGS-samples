#!/bin/bash
set -euo pipefail

# =============================================
# CONFIGURATION
# =============================================
REF_DIR="ref-dbs"
SSU_DB="${REF_DIR}/silva_ssu-20200130/SSU.fasta"
LSU_DB="${REF_DIR}/silva_lsu-20200130/LSU.fasta" 
NONCODING_DIR="noncoding_sequences/samples"
OUTPUT_DIR="mapseq_results"
THREADS=8

# =============================================
# PROCESS SAMPLES
# =============================================
mkdir -p "$OUTPUT_DIR"

# Get all sample names
mapfile -t samples < <(find "$NONCODING_DIR" -name "*_noncoding.fa" | xargs -n1 basename | sed 's/_noncoding.fa//')

# Process each sample
for sample in "${samples[@]}"; do
    echo "Processing $sample..."
    
    # SSU Processing
    mapseq "${NONCODING_DIR}/${sample}_noncoding.fa" "$SSU_DB" "${REF_DIR}/silva_ssu-20200130/slv_ssu_filtered2.txt" \
        > "${OUTPUT_DIR}/${sample}_ssu.mapseq" 2>> "${OUTPUT_DIR}/ssu.log"
    mapseq -otucounts "${OUTPUT_DIR}/${sample}_ssu.mapseq" > "${OUTPUT_DIR}/${sample}_ssu.otu"
    
    # LSU Processing
    mapseq "${NONCODING_DIR}/${sample}_noncoding.fa" "$LSU_DB" "${REF_DIR}/silva_lsu-20200130/slv_lsu_filtered2.txt" \
        > "${OUTPUT_DIR}/${sample}_lsu.mapseq" 2>> "${OUTPUT_DIR}/lsu.log"
    mapseq -otucounts "${OUTPUT_DIR}/${sample}_lsu.mapseq" > "${OUTPUT_DIR}/${sample}_lsu.otu"
done
# =============================================
# FINAL OUTPUT
# =============================================
echo "Pipeline complete. Results:"
echo " - Individual OTU files: ${OUTPUT_DIR}/*.otu"
