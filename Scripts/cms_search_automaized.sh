#!/bin/bash
set -euo pipefail  

### ==================== ###
### USER CONFIGURATION   ###
### ==================== ###

# System Resources
THREADS=8                          # Number of CPU cores for cmsearch
MAX_PARALLEL_SAMPLES=2             # Process this many samples simultaneously

# Input/Output Directories  
INPUT_DIR="fasta_converted"        # Directory containing FASTA files
CM_DIR="ribosome/"                 # Directory with CM files
OUTDIR="./cmsearch_results"        # Output directory for all results
TEMP_DIR="/tmp/cmsearch_$$"        # Temporary directory for intermediate files

# Processing Options
CLEANUP_INTERMEDIATE=true          # Remove intermediate files to save space
COMPRESS_OUTPUT=true               # Compress final outputs
RUN_PARALLEL=true                  # Process multiple samples in parallel
CREATE_BACKUP=false                # Create backup copies of results

# cmsearch Parameters - CHOOSE ONE METHOD
THRESHOLD_METHOD="EVALUE"          # Options: "EVALUE" or "SCORE" 
EVAL_THRESHOLD=10                  # E-value threshold (used if THRESHOLD_METHOD="EVALUE")
MIN_SCORE_THRESHOLD=15             # Score threshold (used if THRESHOLD_METHOD="SCORE")

### ==================== ###
### HELPER FUNCTIONS     ###
### ==================== ###

validate_dependencies() {
    echo "[$(date)] Checking dependencies..." | tee -a "$LOG_FILE"
    
    if ! command -v cmsearch &> /dev/null; then
        echo "ERROR: cmsearch not found in PATH. Please install Infernal." | tee -a "$LOG_FILE"
        exit 1
    fi
    
    if [[ ! -d "$CM_DIR" ]]; then
        echo "ERROR: CM directory not found: $CM_DIR" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    local cm_count=$(find "$CM_DIR" -name "*.cm" | wc -l)
    if [ "$cm_count" -eq 0 ]; then
        echo "ERROR: No CM files found in $CM_DIR" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    # Validate threshold method
    if [[ "$THRESHOLD_METHOD" != "EVALUE" && "$THRESHOLD_METHOD" != "SCORE" ]]; then
        echo "ERROR: THRESHOLD_METHOD must be either 'EVALUE' or 'SCORE'" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "Found $cm_count CM files in $CM_DIR" | tee -a "$LOG_FILE"
    echo "Using threshold method: $THRESHOLD_METHOD" | tee -a "$LOG_FILE"
}

validate_fasta_file() {
    local fasta_file="$1"
    
    if [[ ! -f "$fasta_file" ]] || [[ ! -r "$fasta_file" ]]; then
        echo "ERROR: FASTA file not found or not readable: $fasta_file"
        return 1
    fi
    
    if [[ ! -s "$fasta_file" ]]; then
        echo "ERROR: FASTA file is empty: $fasta_file"
        return 1
    fi
    
    return 0
}

process_sample() {
    local fasta_file="$1"
    local sample="$2"
    
    echo "[$(date)] Processing sample: $sample" | tee -a "$LOG_FILE"
    
    if ! validate_fasta_file "$fasta_file"; then
        echo "SKIPPING sample $sample due to file validation errors" | tee -a "$LOG_FILE"
        return 1
    fi
    
    local sample_temp="$TEMP_DIR/$sample"
    local sample_out1="$OUTDIR/${sample}_primary"
    local sample_out2="$OUTDIR/${sample}_backup"
    
    mkdir -p "$sample_temp" "$sample_out1"
    if [ "$CREATE_BACKUP" = true ]; then
        mkdir -p "$sample_out2"
    fi
    
    local sample_log="$OUTDIR/logs/${sample}_cmsearch.log"
    echo "[$(date)] Starting cmsearch processing for $sample" > "$sample_log"
    echo "Threshold method: $THRESHOLD_METHOD" >> "$sample_log"
    
    local success_count=0
    local total_models=0
    
    for cm_file in "$CM_DIR"/*.cm; do
        [[ ! -f "$cm_file" ]] && continue
        
        local cm_name=$(basename "$cm_file" .cm)
        local tbl_output="$sample_temp/${sample}_${cm_name}.tbl"
        
        echo "   Processing CM Model: $cm_name" | tee -a "$LOG_FILE"
        ((total_models++))
        
        # Build cmsearch command based on threshold method
        local cmsearch_args=(
            --cpu "$THREADS"
            --tblout "$tbl_output"
            --noali
        )
        
        # Add threshold parameter based on user choice
        if [ "$THRESHOLD_METHOD" = "EVALUE" ]; then
            cmsearch_args+=(-E "$EVAL_THRESHOLD")
        else
            cmsearch_args+=(-T "$MIN_SCORE_THRESHOLD")
        fi
        
        if cmsearch "${cmsearch_args[@]}" "$cm_file" "$fasta_file" \
            2>> "$sample_log" > /dev/null; then
            
            if [[ -s "$tbl_output" ]]; then
                mv "$tbl_output" "$sample_out1/"
                
                if [ "$CREATE_BACKUP" = true ]; then
                    cp "$sample_out1/$(basename "$tbl_output")" "$sample_out2/"
                fi
                
                ((success_count++))
                echo "     SUCCESS - hits found" | tee -a "$LOG_FILE"
            else
                echo "     NO HITS - empty output" | tee -a "$LOG_FILE"
            fi
        else
            echo "     FAILED - cmsearch error (see log)" | tee -a "$LOG_FILE"
        fi
    done
    
    if [ "$CLEANUP_INTERMEDIATE" = true ]; then
        echo "[$(date)] Cleaning up temporary files for $sample" | tee -a "$LOG_FILE"
        rm -rf "$sample_temp"
    fi
    
    echo "[$(date)] Sample $sample completed: $success_count/$total_models models successful" | tee -a "$LOG_FILE"
    
    if [ "$success_count" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

### ==================== ###
### MAIN EXECUTION       ###
### ==================== ###

mkdir -p "$OUTDIR/logs" "$TEMP_DIR"

LOG_FILE="$OUTDIR/logs/cmsearch_master.log"
echo "=== CMSEARCH PIPELINE STARTED $(date) ===" | tee "$LOG_FILE"
echo "Configuration:" | tee -a "$LOG_FILE"
echo "- Threads per cmsearch: $THREADS" | tee -a "$LOG_FILE"
echo "- Max parallel samples: $MAX_PARALLEL_SAMPLES" | tee -a "$LOG_FILE"
echo "- Input directory: $INPUT_DIR" | tee -a "$LOG_FILE"
echo "- CM directory: $CM_DIR" | tee -a "$LOG_FILE"
echo "- Output directory: $OUTDIR" | tee -a "$LOG_FILE"
echo "- Threshold method: $THRESHOLD_METHOD" | tee -a "$LOG_FILE"
if [ "$THRESHOLD_METHOD" = "EVALUE" ]; then
    echo "- E-value threshold: $EVAL_THRESHOLD" | tee -a "$LOG_FILE"
else
    echo "- Score threshold: $MIN_SCORE_THRESHOLD" | tee -a "$LOG_FILE"
fi

validate_dependencies

declare -a valid_samples=()
echo "[$(date)] Discovering input FASTA files..." | tee -a "$LOG_FILE"

for fasta_file in "$INPUT_DIR"/*.fa; do
    [[ ! -f "$fasta_file" ]] && continue
    
    sample=$(basename "$fasta_file" .fa)
    
    if validate_fasta_file "$fasta_file"; then
        valid_samples+=("$fasta_file|$sample")
        echo "✓ Valid FASTA file: $sample" | tee -a "$LOG_FILE"
    else
        echo "✗ Invalid FASTA file, skipping: $sample" | tee -a "$LOG_FILE"
    fi
done

if [ ${#valid_samples[@]} -eq 0 ]; then
    echo "ERROR: No valid FASTA files found in $INPUT_DIR" | tee -a "$LOG_FILE"
    echo "Expected naming: *.fa" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] Found ${#valid_samples[@]} valid FASTA files to process" | tee -a "$LOG_FILE"

processed_samples=0
failed_samples=0

if [ "$RUN_PARALLEL" = true ] && [ "$MAX_PARALLEL_SAMPLES" -gt 1 ]; then
    echo "[$(date)] Processing samples in parallel (max: $MAX_PARALLEL_SAMPLES)" | tee -a "$LOG_FILE"
    
    for sample_info in "${valid_samples[@]}"; do
        while [ $(jobs -r | wc -l) -ge "$MAX_PARALLEL_SAMPLES" ]; do
            sleep 5
        done
        
        IFS='|' read -r fasta_file sample <<< "$sample_info"
        
        {
            if process_sample "$fasta_file" "$sample"; then
                echo "SUCCESS: $sample" >> "$OUTDIR/logs/processing_status.tmp"
            else
                echo "FAILED: $sample" >> "$OUTDIR/logs/processing_status.tmp"
            fi
        } &
    done
    
    wait
    
    if [[ -f "$OUTDIR/logs/processing_status.tmp" ]]; then
        processed_samples=$(grep -c "SUCCESS:" "$OUTDIR/logs/processing_status.tmp" || echo 0)
        failed_samples=$(grep -c "FAILED:" "$OUTDIR/logs/processing_status.tmp" || echo 0)
        rm "$OUTDIR/logs/processing_status.tmp"
    fi
    
else
    echo "[$(date)] Processing samples sequentially" | tee -a "$LOG_FILE"
    
    for sample_info in "${valid_samples[@]}"; do
        IFS='|' read -r fasta_file sample <<< "$sample_info"
        
        if process_sample "$fasta_file" "$sample"; then
            ((processed_samples++))
        else
            ((failed_samples++))
        fi
    done
fi

if [ "$CLEANUP_INTERMEDIATE" = true ]; then
    echo "[$(date)] Final cleanup of temporary directory" | tee -a "$LOG_FILE"
    rm -rf "$TEMP_DIR"
fi

echo "=== CMSEARCH PIPELINE COMPLETED ===" | tee -a "$LOG_FILE"
echo "Processing Summary:" | tee -a "$LOG_FILE"
echo "- Total samples found: ${#valid_samples[@]}" | tee -a "$LOG_FILE"
echo "- Successfully processed: $processed_samples" | tee -a "$LOG_FILE"
echo "- Failed samples: $failed_samples" | tee -a "$LOG_FILE"
echo "- Results saved to: $OUTDIR" | tee -a "$LOG_FILE"
echo "- Primary outputs: $OUTDIR/*_primary/" | tee -a "$LOG_FILE"
if [ "$CREATE_BACKUP" = true ]; then
    echo "- Backup copies: $OUTDIR/*_backup/" | tee -a "$LOG_FILE"
fi
echo "- Pipeline finished: $(date)" | tee -a "$LOG_FILE"

if [ "$failed_samples" -gt 0 ]; then
    echo "WARNING: Some samples failed processing. Check individual logs for details." | tee -a "$LOG_FILE"
    exit 2
else
    echo "SUCCESS: All samples processed successfully!" | tee -a "$LOG_FILE"
    exit 0
fi
