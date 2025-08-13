#!/bin/bash
set -euo pipefail  # Exit on error, undefined variables, and pipe failures

### ==================== ###
### USER CONFIGURATION   ###
### ==================== ###

# System Resources - Optimized for WGS
THREADS=10                          # Number of CPU threads to use
MEMORY="10G"                       # Memory limit (increased for WGS)
MAX_PARALLEL_SAMPLES=2             # Process N samples in parallel (adjust based on RAM)

# Input/Output
INPUT_DIR="."                      # Directory containing input FASTQs
OUTDIR="./results_trim_merge_qc"   # Output directory
TEMP_DIR="/tmp/metagenomics_$$"    # Temporary directory for large intermediate files

# Trimmomatic Parameters - WGS optimized
ADAPTER_FILE="TruSeq3-PE.fa"       # Adapter file path
LEADING=3                          # Remove leading bases with quality < this
TRAILING=3                         # Remove trailing bases with quality < this  
SLIDING_WINDOW="4:20"              # Stricter quality for WGS (was 4:15)
MIN_LENGTH=50                      # Longer minimum length for WGS (was 25)

# FLASH Parameters - WGS optimized
MIN_OVERLAP=10                     # Minimum overlap (increased for WGS)
MAX_OVERLAP=300                    # Maximum overlap (increased for WGS)
MISMATCH_RATIO=0.20                # Stricter mismatch ratio (was 0.25)
ALLOW_OUTIES=true                  # Allow "outie" oriented pairs

# Quality Control & Cleanup
RUN_FINAL_QC=true                  # Run MultiQC at end
CLEANUP_INTERMEDIATE=true          # Remove intermediate files to save space
MIN_DISK_SPACE_GB=50               # Minimum free disk space required (GB)

### ==================== ###
### HELPER FUNCTIONS     ###
### ==================== ###

# Function: Check system resources
check_resources() {
    echo "[$(date)] Checking system resources..." | tee -a "$LOG"
    
    # Check available disk space
    available_space=$(df "$OUTDIR" | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$available_space" -lt "$MIN_DISK_SPACE_GB" ]; then
        echo "ERROR: Insufficient disk space. Available: ${available_space}GB, Required: ${MIN_DISK_SPACE_GB}GB" | tee -a "$LOG"
        exit 1
    fi
    
    # Check available memory
    available_mem=$(free -g | awk 'NR==2{print $7}')
    required_mem=$(echo "$MEMORY" | sed 's/G//')
    if [ "$available_mem" -lt "$required_mem" ]; then
        echo "WARNING: Low available memory. Available: ${available_mem}GB, Required: ${required_mem}GB" | tee -a "$LOG"
    fi
    
    echo "Resources OK - Disk: ${available_space}GB, Memory: ${available_mem}GB available" | tee -a "$LOG"
}

# Function: Validate input files
validate_input_files() {
    local r1="$1"
    local r2="$2"
    
    # Check if both files exist
    if [[ ! -f "$r1" ]]; then
        echo "ERROR: R1 file not found: $r1" | tee -a "$LOG"
        return 1
    fi
    
    if [[ ! -f "$r2" ]]; then
        echo "ERROR: R2 file not found: $r2" | tee -a "$LOG"
        return 1
    fi
    
    # Check if files are readable and non-empty
    if [[ ! -r "$r1" ]] || [[ ! -s "$r1" ]]; then
        echo "ERROR: R1 file is not readable or empty: $r1" | tee -a "$LOG"
        return 1
    fi
    
    if [[ ! -r "$r2" ]] || [[ ! -s "$r2" ]]; then
        echo "ERROR: R2 file is not readable or empty: $r2" | tee -a "$LOG"
        return 1
    fi
    
    return 0
}

# Function: Run FastQC with better error handling
run_fastqc() {
    local input_file="$1"
    local sample_name="$2"
    local step="$3"
    
    echo "[$(date)] Running FastQC on $input_file ($step)" | tee -a "$LOG"
    
    if ! fastqc "$input_file" \
        -o "$OUTDIR" \
        -t 2 \
        --noextract \
        --quiet \
        2> "$OUTDIR/logs/${sample_name}_${step}_fastqc.log"; then
        echo "WARNING: FastQC failed for $input_file" | tee -a "$LOG"
        return 1
    fi
    
    return 0
}

# Function: Process a single sample
process_sample() {
    local r1="$1"
    local r2="$2"
    local sample="$3"
    
    echo "=== PROCESSING SAMPLE: $sample ===" | tee -a "$LOG"
    
    # Validate input files first
    if ! validate_input_files "$r1" "$r2"; then
        echo "SKIPPING sample $sample due to file validation errors" | tee -a "$LOG"
        return 1
    fi
    
    # Create sample-specific temp directory
    local sample_temp="$TEMP_DIR/$sample"
    mkdir -p "$sample_temp"
    
    ### STEP 1: ADAPTER TRIMMING ###
    echo "[$(date)] Trimming adapters with Trimmomatic for $sample" | tee -a "$LOG"
    
    # Use sample temp directory for intermediate files
    local trimmed_r1="$sample_temp/${sample}_1_trimmed.fq.gz"
    local trimmed_r2="$sample_temp/${sample}_2_trimmed.fq.gz"
    local unpaired_r1="$sample_temp/${sample}_1_unpaired.fq.gz"
    local unpaired_r2="$sample_temp/${sample}_2_unpaired.fq.gz"
    
    if ! trimmomatic PE \
        -threads "$THREADS" \
        -phred33 \
        "$r1" "$r2" \
        "$trimmed_r1" "$unpaired_r1" \
        "$trimmed_r2" "$unpaired_r2" \
        "ILLUMINACLIP:$ADAPTER_FILE:2:30:10:2:keepBothReads" \
        "LEADING:$LEADING" \
        "TRAILING:$TRAILING" \
        "SLIDINGWINDOW:$SLIDING_WINDOW" \
        "MINLEN:$MIN_LENGTH" \
        2> "$OUTDIR/logs/${sample}_trimmomatic.log"; then
        echo "ERROR: Trimmomatic failed for sample $sample" | tee -a "$LOG"
        return 1
    fi
    
    ### STEP 2: POST-TRIM QUALITY CHECK ###
    echo "[$(date)] Post-trim quality check for $sample" | tee -a "$LOG"
    run_fastqc "$trimmed_r1" "$sample" "trimmed_R1" &
    run_fastqc "$trimmed_r2" "$sample" "trimmed_R2" &
    wait
    
    ### STEP 3: READ MERGING ###
    echo "[$(date)] Merging reads with FLASH for $sample" | tee -a "$LOG"
    
    local flash_cmd=(
        flash
        "$trimmed_r1"
        "$trimmed_r2"
        -o "$sample"
        -d "$sample_temp"
        -m "$MIN_OVERLAP"
        -M "$MAX_OVERLAP"
        -x "$MISMATCH_RATIO"
        -t "$THREADS"
        -z
        --quiet
    )
    
    # Add outie parameter if enabled
    if [ "$ALLOW_OUTIES" = true ]; then
        flash_cmd+=(-O)
    fi
    
    if ! "${flash_cmd[@]}" 2> "$OUTDIR/logs/${sample}_flash.log"; then
        echo "ERROR: FLASH failed for sample $sample" | tee -a "$LOG"
        return 1
    fi
    
    # Move final results to output directory
    if [[ -f "$sample_temp/${sample}.extendedFrags.fastq.gz" ]]; then
        mv "$sample_temp/${sample}.extendedFrags.fastq.gz" "$OUTDIR/${sample}_merged.fq.gz"
        
        ### STEP 4: MERGED READS QUALITY CHECK ###
        echo "[$(date)] Quality check on merged reads for $sample" | tee -a "$LOG"
        run_fastqc "$OUTDIR/${sample}_merged.fq.gz" "$sample" "merged"
        
        # Also move unmerged reads if they exist
        [[ -f "$sample_temp/${sample}.notCombined_1.fastq.gz" ]] && \
            mv "$sample_temp/${sample}.notCombined_1.fastq.gz" "$OUTDIR/${sample}_unmerged_R1.fq.gz"
        [[ -f "$sample_temp/${sample}.notCombined_2.fastq.gz" ]] && \
            mv "$sample_temp/${sample}.notCombined_2.fastq.gz" "$OUTDIR/${sample}_unmerged_R2.fq.gz"
    else
        echo "WARNING: No merged reads generated for sample $sample" | tee -a "$LOG"
    fi
    
    # Cleanup intermediate files if requested
    if [ "$CLEANUP_INTERMEDIATE" = true ]; then
        echo "[$(date)] Cleaning up intermediate files for $sample" | tee -a "$LOG"
        rm -rf "$sample_temp"
    fi
    
    echo "[$(date)] Sample $sample processing completed successfully!" | tee -a "$LOG"
    return 0
}

### ==================== ###
### PIPELINE EXECUTION   ###
### ==================== ###

# Create output directories
mkdir -p "$OUTDIR/logs" "$TEMP_DIR"

# Initialize logging
LOG="$OUTDIR/logs/pipeline.log"
echo "=== WGS METAGENOMICS PREPROCESSING PIPELINE STARTED $(date) ===" | tee "$LOG"
echo "Configuration:" | tee -a "$LOG"
echo "- Threads: $THREADS" | tee -a "$LOG"
echo "- Memory: $MEMORY" | tee -a "$LOG"
echo "- Max parallel samples: $MAX_PARALLEL_SAMPLES" | tee -a "$LOG"
echo "- Input directory: $INPUT_DIR" | tee -a "$LOG"
echo "- Output directory: $OUTDIR" | tee -a "$LOG"

# Check system resources
check_resources

# Find all R1 files and validate corresponding R2 files exist
declare -a valid_samples=()
echo "[$(date)] Discovering and validating input files..." | tee -a "$LOG"

for r1 in "$INPUT_DIR"/*_R1.fastq* "$INPUT_DIR"/*_1.fastq*; do
    [[ ! -f "$r1" ]] && continue  # Skip if no files match pattern
    
    # Try different R2 naming conventions
    r2=""
    if [[ "$r1" == *"_R1."* ]]; then
        r2=${r1/_R1./_R2.}
    elif [[ "$r1" == *"_1."* ]]; then
        r2=${r1/_1./_2.}
    fi
    
    # Extract sample name
    sample=$(basename "$r1" | sed -E 's/_(R1|1)\.(fastq|fq).*//')
    
    if validate_input_files "$r1" "$r2"; then
        valid_samples+=("$r1|$r2|$sample")
        echo "✓ Valid sample pair found: $sample" | tee -a "$LOG"
    else
        echo "✗ Invalid sample pair, skipping: $sample" | tee -a "$LOG"
    fi
done

# Check if any valid samples were found
if [ ${#valid_samples[@]} -eq 0 ]; then
    echo "ERROR: No valid sample pairs found in $INPUT_DIR" | tee -a "$LOG"
    echo "Expected naming: *_R1.fastq* & *_R2.fastq* OR *_1.fastq* & *_2.fastq*" | tee -a "$LOG"
    exit 1
fi

echo "[$(date)] Found ${#valid_samples[@]} valid sample pairs to process" | tee -a "$LOG"

# Process samples (with optional parallelization)
processed_samples=0
failed_samples=0

if [ "$MAX_PARALLEL_SAMPLES" -eq 1 ]; then
    # Sequential processing
    for sample_info in "${valid_samples[@]}"; do
        IFS='|' read -r r1 r2 sample <<< "$sample_info"
        if process_sample "$r1" "$r2" "$sample"; then
            ((processed_samples++))
        else
            ((failed_samples++))
        fi
    done
else
    # Parallel processing (simple version)
    echo "[$(date)] Processing samples in parallel (max: $MAX_PARALLEL_SAMPLES)" | tee -a "$LOG"
    
    for sample_info in "${valid_samples[@]}"; do
        # Wait if we've reached max parallel processes
        while [ $(jobs -r | wc -l) -ge "$MAX_PARALLEL_SAMPLES" ]; do
            sleep 5
        done
        
        IFS='|' read -r r1 r2 sample <<< "$sample_info"
        {
            if process_sample "$r1" "$r2" "$sample"; then
                echo "SUCCESS: $sample" >> "$OUTDIR/logs/processing_status.tmp"
            else
                echo "FAILED: $sample" >> "$OUTDIR/logs/processing_status.tmp"
            fi
        } &
    done
    
    # Wait for all background jobs to complete
    wait
    
    # Count results
    if [[ -f "$OUTDIR/logs/processing_status.tmp" ]]; then
        processed_samples=$(grep -c "SUCCESS:" "$OUTDIR/logs/processing_status.tmp" || echo 0)
        failed_samples=$(grep -c "FAILED:" "$OUTDIR/logs/processing_status.tmp" || echo 0)
        rm "$OUTDIR/logs/processing_status.tmp"
    fi
fi

### FINAL QUALITY REPORT ###
if [ "$RUN_FINAL_QC" = true ] && [ "$processed_samples" -gt 0 ]; then
    echo "[$(date)] Generating comprehensive MultiQC report" | tee -a "$LOG"
    
    if ! multiqc "$OUTDIR" \
        -o "$OUTDIR" \
        --filename "multiqc_report_$(date +%Y%m%d)" \
        --title "WGS Metagenomics Preprocessing Report" \
        --comment "Pipeline run on $(date)" \
        --quiet \
        2> "$OUTDIR/logs/multiqc.log"; then
        echo "WARNING: MultiQC report generation failed" | tee -a "$LOG"
    fi
fi

# Final cleanup
if [ "$CLEANUP_INTERMEDIATE" = true ]; then
    echo "[$(date)] Final cleanup of temporary files" | tee -a "$LOG"
    rm -rf "$TEMP_DIR"
fi

### PIPELINE SUMMARY ###
echo "=== PIPELINE COMPLETED ===" | tee -a "$LOG"
echo "Processing Summary:" | tee -a "$LOG"
echo "- Total samples found: ${#valid_samples[@]}" | tee -a "$LOG"
echo "- Successfully processed: $processed_samples" | tee -a "$LOG"
echo "- Failed samples: $failed_samples" | tee -a "$LOG"
echo "- Results saved to: $OUTDIR" | tee -a "$LOG"
echo "- Pipeline finished: $(date)" | tee -a "$LOG"

# Exit with appropriate code
if [ "$failed_samples" -gt 0 ]; then
    echo "WARNING: Some samples failed processing. Check logs for details." | tee -a "$LOG"
    exit 2
else
    echo "SUCCESS: All samples processed successfully!" | tee -a "$LOG"
    exit 0
fi
