#!/bin/bash
set -euo pipefail

# =============================================
# CONFIGURATION
# =============================================
MASKED_DIR="masked_results"
FGS_OUTPUT="fraggenescan_results"
FGS_DIR="FragGeneScan-master"
TOTAL_THREADS=$(nproc --all || sysctl -n hw.ncpu)
SAMPLES_PER_BATCH=4  # Number of concurrent samples
FGS_THREADS=$(( TOTAL_THREADS / SAMPLES_PER_BATCH ))  # Threads per sample
LOG_DIR="$FGS_OUTPUT/logs"
TRAIN_SET="illumina_10"

# =============================================
# INITIALIZATION
# =============================================
mkdir -p "$FGS_OUTPUT" "$LOG_DIR"
:> "$LOG_DIR/success.log"
:> "$LOG_DIR/errors.log"

{
echo "=== FragGeneScan STARTED $(date) ==="
echo "Total system threads: $TOTAL_THREADS"
echo "Concurrent samples: $SAMPLES_PER_BATCH"
echo "Threads per sample: $FGS_THREADS"
} | tee "$LOG_DIR/processing.log"

# =============================================
# VALIDATION (unchanged)
# =============================================
if [[ ! -f "$FGS_DIR/run_FragGeneScan.pl" ]]; then
    echo "ERROR: run_FragGeneScan.pl not found in $FGS_DIR" | tee -a "$LOG_DIR/processing.log"
    exit 1
fi

if [[ ! -f "$FGS_DIR/train/$TRAIN_SET" ]]; then
    echo "WARNING: Training set '$TRAIN_SET' not found. Available sets:" | tee -a "$LOG_DIR/processing.log"
    ls "$FGS_DIR/train/" | tee -a "$LOG_DIR/processing.log"
    TRAIN_SET="complete"
    echo "Falling back to: $TRAIN_SET" | tee -a "$LOG_DIR/processing.log"
fi

if [[ $(find "$MASKED_DIR" -name "*_masked.fa" | wc -l) -eq 0 ]]; then
    echo "ERROR: No masked FASTA files in $MASKED_DIR" | tee -a "$LOG_DIR/processing.log"
    exit 1
fi

# =============================================
# PROCESSING FUNCTION (updated for hybrid parallel)
# =============================================
process_sample() {
    local masked_file="$1"
    local sample=$(basename "$masked_file" _masked.fa)
    local out_prefix="$FGS_OUTPUT/$sample"
    
    echo "[$(date +'%T')] Processing: $sample (Threads: $FGS_THREADS)" | tee -a "$LOG_DIR/processing.log"
    
    if ! perl "$FGS_DIR/run_FragGeneScan.pl" \
        -genome="$masked_file" \
        -out="$out_prefix" \
        -complete=1 \
        -train="$TRAIN_SET" \
        -thread="$FGS_THREADS" \  # Key change: Now using multiple threads per sample
        2> "$LOG_DIR/${sample}_error.log"; then
        echo "FAILED: $sample" >> "$LOG_DIR/errors.log"
        return 1
    fi
    
    if [[ -f "${out_prefix}.faa" ]]; then
        echo "SUCCESS: $sample" >> "$LOG_DIR/success.log"
        echo "  Predicted $(grep -c '^>' "${out_prefix}.faa") proteins" | tee -a "$LOG_DIR/processing.log"
    else
        echo "FAILED: $sample" >> "$LOG_DIR/errors.log"
        return 1
    fi
}

export -f process_sample
export FGS_DIR FGS_OUTPUT TRAIN_SET LOG_DIR FGS_THREADS

# =============================================
# EXECUTION (updated parallelism)
# =============================================
echo "Starting processing with $SAMPLES_PER_BATCH concurrent samples ($FGS_THREADS threads each)..." | tee -a "$LOG_DIR/processing.log"
find "$MASKED_DIR" -name "*_masked.fa" -print0 | \
    xargs -0 -P "$SAMPLES_PER_BATCH" -I {} bash -c 'process_sample "$@"' _ {}

# =============================================
# POST-PROCESSING (unchanged)
# =============================================
cat "$FGS_OUTPUT"/*.faa > "$FGS_OUTPUT/combined_predictions.faa" 2>/dev/null || true
cat "$FGS_OUTPUT"/*.ffn > "$FGS_OUTPUT/combined_genes.ffn" 2>/dev/null || true

{
echo "=== SUMMARY ==="
echo "Training set used: $TRAIN_SET"
echo "Samples processed: $(find "$MASKED_DIR" -name "*_masked.fa" | wc -l)"
echo "Successful: $(wc -l < "$LOG_DIR/success.log")"
echo "Failed: $(wc -l < "$LOG_DIR/errors.log")"
echo "Total proteins: $(grep -c '^>' "$FGS_OUTPUT/combined_predictions.faa" 2>/dev/null || echo 0)"
echo "Total genes: $(grep -c '^>' "$FGS_OUTPUT/combined_genes.ffn" 2>/dev/null || echo 0)"
echo "=== END ==="
} | tee -a "$LOG_DIR/processing.log"

[[ $(wc -l < "$LOG_DIR/errors.log") -gt 0 ]] && exit 1 || exit 0
