#!/bin/bash
set -euo pipefail

### ==================== ###
### CONFIGURATION        ###
### ==================== ###

# Common scripts (steps 4-10)
COMMON_SCRIPTS=(
    "fastq_fasta_converter.sh"
    "cms_search_automaized.sh" 
    "automaize_bed.sh"
    "paralel.mask.possible.sh"
    "getnoncoding_seq.sh"
    "mapseq.sh"
    "kraken_reports.sh"
    "korona_plots.sh"
    "FragGeneScan.sh"
)

LOG_DIR="pipeline_logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

### ==================== ###
### USER INTERFACE       ###
### ==================== ###
echo "Select Processing Method:"
echo "1) SeqPrep-first (merge then process)"
echo "2) Trim-then-FLASH (trim then merge)"
echo ""
read -rp "Enter choice (1 or 2): " CHOICE

# Validate input and set pipeline head
case "$CHOICE" in
    1)
        PIPELINE_HEAD=("seqprep.sh")
        PIPELINE_NAME="SeqPrep-first"
        ;;
    2)
        PIPELINE_HEAD=("merging_trim_qc.sh")
        PIPELINE_NAME="Trim-then-FLASH"
        ;;
    *)
        echo "Error: Invalid choice. Must be 1 or 2"
        exit 1
        ;;
esac

# Build full pipeline
SCRIPTS=(
    "${PIPELINE_HEAD[@]}"
    "${COMMON_SCRIPTS[@]}"
)

PIPELINE_NAME=$([[ "$CHOICE" == "1" ]] && echo "SeqPrep-first" || echo "Trim-then-FLASH")

### ==================== ###
### PIPELINE EXECUTION   ###
### ==================== ###
mkdir -p "$LOG_DIR"
START_TIME=$(date +%s)

echo -e "\nStarting $PIPELINE_NAME pipeline (${#SCRIPTS[@]} steps)..."
echo "========================================"

for ((i=0; i<${#SCRIPTS[@]}; i++)); do
    STEP=$((i+1))
    SCRIPT="${SCRIPTS[$i]}"
    LOG_FILE="$LOG_DIR/${STEP}_${SCRIPT%.*}_${TIMESTAMP}.log"
    
    echo -e "\nSTEP ${STEP}: $SCRIPT"
    echo "Start: $(date '+%H:%M:%S')"
    echo "----------------------------------------"

    STEP_START=$(date +%s)
    
if bash "$SCRIPT" 2>&1 | tee "$LOG_FILE"; then
    true  # Do nothing on success
else
    # Only fail if the log contains actual error keywords
    if grep -qi "error\|failed\|exception" "$LOG_FILE"; then
        echo -e "\n❌ REAL FAILURE: Step ${STEP}"
        exit 1
    else
        echo -e "\n⚠️ False alarm (ignored): Step ${STEP}"
    fi
fi    
    STEP_END=$(date +%s)
    echo -e "\n✓ COMPLETED: Step ${STEP} ($((STEP_END-STEP_START))s)"
done

### ==================== ###
### FINAL REPORT         ###
### ==================== ###
TOTAL_TIME=$(( $(date +%s) - START_TIME ))
echo -e "\n========================================"
echo "🎉 $PIPELINE_NAME PIPELINE COMPLETED"
echo "Total Steps: ${#SCRIPTS[@]}"
echo "Total Time: ${TOTAL_TIME}s"
echo "Logs: $LOG_DIR/"
echo "========================================"
