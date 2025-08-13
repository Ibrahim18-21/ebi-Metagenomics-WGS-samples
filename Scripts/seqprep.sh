#!/bin/bash
set -euo pipefail

### ==================== ###
### USER CONFIGURATION   ###
### ==================== ###

# System Resources
THREADS=10
MAX_PARALLEL_SAMPLES=2
MEMORY="10G"

# Input/Output
INPUT_DIR="."
OUTDIR="./results_trim_merge_qc"
TEMP_DIR="/tmp/seqprep_$$"

# SeqPrep Parameters
ADAPTER_A="GATCGGAAGAGCACACG"
ADAPTER_B="AGATCGGAAGAGCGTCGT"

# Trimmomatic Parameters
ADAPTER_FILE="adaptornf.fa"
LEADING=3
TRAILING=3
SLIDING_WINDOW="4:15"
MIN_LENGTH=36

### ==================== ###
### CORE PROCESSING      ###
### ==================== ###

process_sample() {
    local R1="$1"
    local R2="$2"
    local SAMPLE="$3"
    
    echo "[$(date)] Processing $SAMPLE" | tee -a "$LOG"
    
    # STEP 1: Merge with SeqPrep (output: _Merged.fq.gz)
    echo "[$(date)] Merging $SAMPLE" | tee -a "$LOG"
    SeqPrep \
        -f "$R1" \
        -r "$R2" \
        -1 "$OUTDIR/${SAMPLE}_Unmerged_R1.fastq" \
        -2 "$OUTDIR/${SAMPLE}_Unmerged_R2.fastq" \
        -A "$ADAPTER_A" \
        -B "$ADAPTER_B" \
        -s "$OUTDIR/${SAMPLE}_Merged.fq.gz" \
        2> "$OUTDIR/logs/${SAMPLE}_seqprep.log"
    
    # Verify merge succeeded
    if [[ ! -f "$OUTDIR/${SAMPLE}_Merged.fq.gz" ]]; then
        echo "ERROR: Merging failed for $SAMPLE" | tee -a "$LOG"
        return 1
    fi
    
    # STEP 2: FastQC on merged reads
    echo "[$(date)] FastQC (merged) for $SAMPLE" | tee -a "$LOG"
    fastqc "$OUTDIR/${SAMPLE}_Merged.fq.gz" \
        -o "$OUTDIR" \
        --quiet \
        2> "$OUTDIR/logs/${SAMPLE}_fastqc_merged.log"
    
    # STEP 3: Trim merged reads (output: _Trimmed_merged.fq.gz)
    echo "[$(date)] Trimming $SAMPLE" | tee -a "$LOG"
    trimmomatic SE \
        -threads "$THREADS" \
        -phred33 \
        "$OUTDIR/${SAMPLE}_Merged.fq.gz" \
        "$OUTDIR/${SAMPLE}_Trimmed_merged.fq.gz" \
        "ILLUMINACLIP:$ADAPTER_FILE:2:30:10" \
        "LEADING:$LEADING" \
        "TRAILING:$TRAILING" \
        "SLIDINGWINDOW:$SLIDING_WINDOW" \
        "MINLEN:$MIN_LENGTH" \
        2> "$OUTDIR/logs/${SAMPLE}_trimmomatic.log"
    
    # STEP 4: FastQC on trimmed reads
    echo "[$(date)] FastQC (trimmed) for $SAMPLE" | tee -a "$LOG"
    fastqc "$OUTDIR/${SAMPLE}_Trimmed_merged.fq.gz" \
        -o "$OUTDIR" \
        --quiet \
        2> "$OUTDIR/logs/${SAMPLE}_fastqc_trimmed.log"
    
    echo "[$(date)] Completed $SAMPLE" | tee -a "$LOG"
}

### ==================== ###
### MAIN EXECUTION       ###
### ==================== ###

# Initialize
mkdir -p "$OUTDIR/logs"
LOG="$OUTDIR/logs/pipeline.log"
echo "=== PARALLEL MERGE-TRIM-QC PIPELINE STARTED $(date) ===" | tee "$LOG"
echo "Config: $MAX_PARALLEL_SAMPLES parallel samples, $THREADS threads/sample" | tee -a "$LOG"

# Discover samples (case-insensitive matching)
SAMPLES=()
while IFS= read -r -d '' R1; do
    R2="${R1/_1.fastq/_2.fastq}"
    R2="${R2/_R1.fastq/_R2.fastq}"
    SAMPLE=$(basename "$R1" | sed -E 's/_[12Rr].fastq.*//i')
    SAMPLES+=("$R1|$R2|$SAMPLE")
done < <(find "$INPUT_DIR" \( -iname "*_1.fastq*" -o -iname "*_R1.fastq*" \) -print0)

# Process in parallel
for sample_info in "${SAMPLES[@]}"; do
    while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL_SAMPLES ]; do
        sleep 5
    done
    
    IFS='|' read -r R1 R2 SAMPLE <<< "$sample_info"
    (
        process_sample "$R1" "$R2" "$SAMPLE" || \
        echo "FAILED: $SAMPLE" >> "$OUTDIR/logs/failed_samples.txt"
    ) &
done

wait

# Final QC
if command -v multiqc &> /dev/null; then
    echo "[$(date)] Generating MultiQC report" | tee -a "$LOG"
    multiqc "$OUTDIR" -o "$OUTDIR" --quiet 2>> "$LOG"
fi

# Summary
FAILED=$([ -f "$OUTDIR/logs/failed_samples.txt" ] && wc -l < "$OUTDIR/logs/failed_samples.txt" || echo 0)
echo "=== PIPELINE COMPLETED $(date) ===" | tee -a "$LOG"
echo "SUMMARY:" | tee -a "$LOG"
echo "- Total samples: ${#SAMPLES[@]}" | tee -a "$LOG"
echo "- Success: $((${#SAMPLES[@]} - FAILED))" | tee -a "$LOG"
echo "- Failed: $FAILED" | tee -a "$LOG"

exit $((FAILED > 0 ? 1 : 0))
