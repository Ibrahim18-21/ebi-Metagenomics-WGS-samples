#!/bin/bash
set -euo pipefail

### ==================== ###
### USER CONFIGURATION   ###
### ==================== ###

# System Resources
THREADS=10                          # Number of CPU threads
MEMORY="10G"                       # Memory limit
MAX_PARALLEL_SAMPLES=2             # Process N samples in parallel

# Input/Output
INPUT_DIR="."                      # Directory containing input FASTQs
OUTDIR="./seqprep_results"         # Output directory
TEMP_DIR="/tmp/seqprep_$$"         # Temporary directory

# Trimmomatic Parameters
ADAPTER_FILE="TruSeq3-PE.fa"       # Adapter file path
LEADING=3                          # Remove leading bases with quality < this
TRAILING=3                         # Remove trailing bases with quality < this
SLIDING_WINDOW="4:20"              # Window size:quality threshold
MIN_LENGTH=50                      # Minimum read length after trimming

# SeqPrep Parameters (Lenient Settings)
MIN_OVERLAP=10                     # Minimum overlap length
MIN_LENGTH_SEQPREP=10              # Minimum read length after merging
QUALITY_THRESHOLD=0                # Quality threshold (0 = most lenient)
MISMATCH_FRACTION=1.0              # Allow 100% mismatches
MIN_OVERLAP_FRACTION=100           # Minimum overlap as fraction of read
ERROR_RATE=0.9                     # Maximum error rate

# Quality Control
RUN_FASTQC=false                    # Run FastQC on raw reads
RUN_FINAL_QC=true                  # Run MultiQC at end

# Cleanup
CLEANUP_INTERMEDIATE=true          # Remove intermediate files
MIN_DISK_SPACE_GB=50               # Minimum free disk space required (GB)

### ==================== ###
### HELPER FUNCTIONS     ###
### ==================== ###

check_resources() {
    echo "[$(date)] Checking system resources..." | tee -a "$LOG"
    
    # Check disk space
    available_space=$(df "$OUTDIR" | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$available_space" -lt "$MIN_DISK_SPACE_GB" ]; then
        echo "ERROR: Insufficient disk space. Available: ${available_space}GB, Required: ${MIN_DISK_SPACE_GB}GB" | tee -a "$LOG"
        exit 1
    fi
    
    # Check memory
    available_mem=$(free -g | awk 'NR==2{print $7}')
    required_mem=$(echo "$MEMORY" | sed 's/G//')
    if [ "$available_mem" -lt "$required_mem" ]; then
        echo "WARNING: Low available memory. Available: ${available_mem}GB, Required: ${required_mem}GB" | tee -a "$LOG"
    fi
}

validate_input_files() {
    local r1="$1"
    local r2="$2"
    
    if [[ ! -f "$r1" ]]; then
        echo "ERROR: R1 file not found: $r1" | tee -a "$LOG"
        return 1
    fi
    
    if [[ ! -f "$r2" ]]; then
        echo "ERROR: R2 file not found: $r2" | tee -a "$LOG"
        return 1
    fi
    
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

run_fastqc() {
    local input_file="$1"
    local sample_name="$2"
    local step="$3"
    
    if [ "$RUN_FASTQC" = false ]; then
        return 0
    fi
    
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

### ==================== ###
### PROCESSING FUNCTIONS ###
### ==================== ###

trim_reads() {
    local r1="$1"
    local r2="$2"
    local sample="$3"
    local outdir="$4"
    
    echo "[$(date)] Trimming adapters with Trimmomatic for $sample" | tee -a "$LOG"
    
    local trimmed_r1="$outdir/${sample}_1_trimmed.fq.gz"
    local trimmed_r2="$outdir/${sample}_2_trimmed.fq.gz"
    local unpaired_r1="$outdir/${sample}_1_unpaired.fq.gz"
    local unpaired_r2="$outdir/${sample}_2_unpaired.fq.gz"
    
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
    
    # Run FastQC on trimmed reads
    run_fastqc "$trimmed_r1" "$sample" "trimmed_R1" &
    run_fastqc "$trimmed_r2" "$sample" "trimmed_R2" &
    wait
    
    echo "$trimmed_r1|$trimmed_r2"  # Return paths to trimmed files
}

merge_reads() {
    local r1="$1"
    local r2="$2"
    local sample="$3"
    local outdir="$4"
    
    echo "[$(date)] Merging reads with SeqPrep for $sample" | tee -a "$LOG"
    
    local merged_output="$outdir/${sample}_merged.fastq.gz"
    local unmerged_r1="$outdir/${sample}_unmerged_R1.fastq.gz"
    local unmerged_r2="$outdir/${sample}_unmerged_R2.fastq.gz"
    
    if ! SeqPrep \
        -f "$r1" \
        -r "$r2" \
        -1 >(gzip > "$unmerged_r1") \
        -2 >(gzip > "$unmerged_r2") \
        -s >(gzip > "$merged_output") \
        -t "$THREADS" \
        -m "$MIN_OVERLAP" \
        -q "$QUALITY_THRESHOLD" \
        -n "$MISMATCH_FRACTION" \
        -o "$MIN_OVERLAP_FRACTION" \
        -e "$ERROR_RATE" \
        2> "$OUTDIR/logs/${sample}_seqprep.log"; then
        echo "ERROR: SeqPrep failed for sample $sample" | tee -a "$LOG"
        return 1
    fi
    
    # Run FastQC on merged reads
    if [[ -f "$merged_output" ]]; then
        run_fastqc "$merged_output" "$sample" "merged"
    fi
    
    echo "$merged_output"  # Return path to merged file
}

process_sample() {
    local r1="$1"
    local r2="$2"
    local sample="$3"
    
    echo "=== PROCESSING SAMPLE: $sample ===" | tee -a "$LOG"
    
    # Validate input files
    if ! validate_input_files "$r1" "$r2"; then
        echo "SKIPPING sample $sample due to file validation errors" | tee -a "$LOG"
        return 1
    fi
    
    # Create sample-specific temp directory
    local sample_temp="$TEMP_DIR/$sample"
    mkdir -p "$sample_temp"
    
    # Initial FastQC (optional)
    if [ "$RUN_FASTQC" = true ]; then
        run_fastqc "$r1" "$sample" "raw_R1" &
        run_fastqc "$r2" "$sample" "raw_R2" &
        wait
    fi
    
    # Step 1: Adapter trimming
    trimmed_files=$(trim_reads "$r1" "$r2" "$sample" "$sample_temp")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    IFS='|' read -r trimmed_r1 trimmed_r2 <<< "$trimmed_files"
    
    # Step 2: Read merging
    merged_file=$(merge_reads "$trimmed_r1" "$trimmed_r2" "$sample" "$OUTDIR")
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Cleanup
    if [ "$CLEANUP_INTERMEDIATE" = true ]; then
        echo "[$(date)] Cleaning up intermediate files for $sample" | tee -a "$LOG"
        rm -rf "$sample_temp"
    fi
    
    echo "[$(date)] Sample $sample processing completed successfully!" | tee -a "$LOG"
    return 0
}

### ==================== ###
### MAIN EXECUTION       ###
### ==================== ###

# Create output directories
mkdir -p "$OUTDIR/logs" "$TEMP_DIR"

# Initialize logging
LOG="$OUTDIR/logs/pipeline.log"
echo "=== SEQPREP WITH TRIMMING PIPELINE STARTED $(date) ===" | tee "$LOG"
echo "Configuration:" | tee -a "$LOG"
echo "- Threads: $THREADS" | tee -a "$LOG"
echo "- Memory: $MEMORY" | tee -a "$LOG"
echo "- Max parallel samples: $MAX_PARALLEL_SAMPLES" | tee -a "$LOG"

# Check system resources
check_resources

# Check for required programs
for cmd in trimmomatic SeqPrep fastqc; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: $cmd not found in PATH" | tee -a "$LOG"
        exit 1
    fi
done

# Find and validate input files
declare -a valid_samples=()
echo "[$(date)] Discovering input files..." | tee -a "$LOG"

for r1 in "$INPUT_DIR"/*_R1.fastq* "$INPUT_DIR"/*_1.fastq*; do
    [[ ! -f "$r1" ]] && continue
    
    # Derive R2 filename
    r2=""
    if [[ "$r1" == *"_R1."* ]]; then
        r2=${r1/_R1./_R2.}
    elif [[ "$r1" == *"_1."* ]]; then
        r2=${r1/_1./_2.}
    fi
    
    sample=$(basename "$r1" | sed -E 's/_(R1|1)\.(fastq|fq).*//')
    
    if validate_input_files "$r1" "$r2"; then
        valid_samples+=("$r1|$r2|$sample")
        echo "✓ Valid sample pair: $sample" | tee -a "$LOG"
    else
        echo "✗ Invalid sample pair, skipping: $sample" | tee -a "$LOG"
    fi
done

# Check if any valid samples were found
if [ ${#valid_samples[@]} -eq 0 ]; then
    echo "ERROR: No valid sample pairs found in $INPUT_DIR" | tee -a "$LOG"
    exit 1
fi

echo "[$(date)] Found ${#valid_samples[@]} valid sample pairs to process" | tee -a "$LOG"

# Process samples
processed_samples=0
failed_samples=0

if [ "$MAX_PARALLEL_SAMPLES" -gt 1 ]; then
    # Parallel processing
    echo "[$(date)] Processing samples in parallel (max: $MAX_PARALLEL_SAMPLES)" | tee -a "$LOG"
    
    for sample_info in "${valid_samples[@]}"; do
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
    
    wait
    
    # Count results
    if [[ -f "$OUTDIR/logs/processing_status.tmp" ]]; then
        processed_samples=$(grep -c "SUCCESS:" "$OUTDIR/logs/processing_status.tmp")
        failed_samples=$(grep -c "FAILED:" "$OUTDIR/logs/processing_status.tmp")
        rm "$OUTDIR/logs/processing_status.tmp"
    fi
else
    # Sequential processing
    for sample_info in "${valid_samples[@]}"; do
        IFS='|' read -r r1 r2 sample <<< "$sample_info"
        if process_sample "$r1" "$r2" "$sample"; then
            ((processed_samples++))
        else
            ((failed_samples++))
        fi
    done
fi

# Final MultiQC report
if [ "$RUN_FINAL_QC" = true ] && [ "$processed_samples" -gt 0 ]; then
    echo "[$(date)] Generating MultiQC report" | tee -a "$LOG"
    multiqc "$OUTDIR" -o "$OUTDIR" --quiet 2> "$OUTDIR/logs/multiqc.log" || true
fi

# Final cleanup
if [ "$CLEANUP_INTERMEDIATE" = true ]; then
    rm -rf "$TEMP_DIR"
fi

# Pipeline summary
echo "=== PIPELINE COMPLETED ===" | tee -a "$LOG"
echo "Summary:" | tee -a "$LOG"
echo "- Total samples: ${#valid_samples[@]}" | tee -a "$LOG"
echo "- Successfully processed: $processed_samples" | tee -a "$LOG"
echo "- Failed samples: $failed_samples" | tee -a "$LOG"
echo "- Results in: $OUTDIR" | tee -a "$LOG"
echo "- Finished: $(date)" | tee -a "$LOG"

exit $((failed_samples > 0 ? 2 : 0))
