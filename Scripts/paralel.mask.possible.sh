#!/bin/bash

# =============================================
# CONFIGURATION
# =============================================
BED_DIR="cmsearch_results"         # Directory with _combined.bed files
FASTA_DIR="fasta_converted"       # Directory with sample_merged.fa files
MASKED_OUTPUT="./masked_results"  # Output directory
THREADS=8                         # CPU threads available
MASK_CHAR="X"                     # Character for masking

# =============================================
# SETUP AND VALIDATION
# =============================================
mkdir -p "$MASKED_OUTPUT"
LOG_FILE="${MASKED_OUTPUT}/processing.log"
SUCCESS_LOG="${MASKED_OUTPUT}/success.log"
ERROR_LOG="${MASKED_OUTPUT}/errors.log"
WARNING_LOG="${MASKED_OUTPUT}/warnings.log"

# Create log files
touch "$SUCCESS_LOG" "$ERROR_LOG" "$WARNING_LOG"

# Check required directories exist
if [[ ! -d "$BED_DIR" ]]; then
    echo "ERROR: BED directory not found: $BED_DIR" | tee "$LOG_FILE"
    exit 1
fi

if [[ ! -d "$FASTA_DIR" ]]; then
    echo "ERROR: FASTA directory not found: $FASTA_DIR" | tee -a "$LOG_FILE"
    exit 1
fi

# =============================================
# MAIN PROCESSING
# =============================================
echo "=== MASKING STARTED $(date) ===" | tee -a "$LOG_FILE"

# Function to process each sample
process_sample() {
    local combined_bed="$1"
    local sample=$(basename "$combined_bed" "_combined.bed")
    local input_fasta="${FASTA_DIR}/${sample}.fa"
    local masked_fasta="${MASKED_OUTPUT}/${sample}_masked.fa"

    {
    echo "=== PROCESSING $sample ==="
    echo " - BED file: $combined_bed"
    echo " - Input FASTA: $input_fasta"

    # Validate inputs exist
    if [[ ! -f "$input_fasta" ]]; then
        echo "ERROR: Missing FASTA file ($input_fasta)" | tee -a "$ERROR_LOG"
        return  # Skip to next sample
    fi

    echo " - Masking with bedtools..."
    if bedtools maskfasta \
        -fi "$input_fasta" \
        -bed "$combined_bed" \
        -fo "$masked_fasta" \
        -mc "$MASK_CHAR" 2>&1; then
        
        # Verify output was created
        if [[ -s "$masked_fasta" ]]; then
            echo "SUCCESS: Created masked FASTA ($(wc -l < "$masked_fasta" | awk '{print $1/2}') sequences)"
            echo "$sample" >> "$SUCCESS_LOG"
        else
            echo "WARNING: Empty output file created" | tee -a "$WARNING_LOG"
            echo "$sample" >> "$WARNING_LOG"
        fi
    else
        echo "ERROR: Masking failed for $sample" | tee -a "$ERROR_LOG"
        [[ -f "$masked_fasta" ]] && rm "$masked_fasta"
    fi
    
    echo  # Blank line for readability
    } | tee -a "$LOG_FILE" "${MASKED_OUTPUT}/${sample}_masking.log"
}

# Export the function and variables for parallel execution
export -f process_sample
export MASKED_OUTPUT
export SUCCESS_LOG
export ERROR_LOG
export WARNING_LOG
export FASTA_DIR
export MASK_CHAR

# Process each BED file in parallel
find "$BED_DIR" -type f -name "*_combined.bed" | parallel -j "$THREADS" process_sample

# =============================================
# FINAL REPORT
# =============================================
{
echo "=== MASKING COMPLETE $(date) ==="
echo "Results in: $MASKED_OUTPUT"
echo "Successful samples: $(wc -l < "$SUCCESS_LOG" 2>/dev/null || echo 0)"
echo "Warned samples: $(wc -l < "$WARNING_LOG" 2>/dev/null || echo 0)"
echo "Failed samples: $(wc -l < "$ERROR_LOG" 2>/dev/null || echo 0)"
} | tee -a "$LOG_FILE"
