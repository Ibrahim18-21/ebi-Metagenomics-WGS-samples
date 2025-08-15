# ebi-Metagenomics-WGS-samples
This pipeline is to automatically process fastq files from the user to merge, trimm, run quality control,  masking and predicting non coding sequences to ultimately identify the taxonomic profile of samples and visualize them using krona tool,  and lastly predict coding sequences.

NOTE: This pipeline was developed for WGS paired end reads but with some edits on it, it can run on any sample and any type of sequencing.

<img width="1280" height="720" alt="Workflow of EBI Metagenomics pipeline WGS" src="https://github.com/user-attachments/assets/139b8529-f763-4c07-8ce6-ba8a100366d3" />

# Metagenomics Pipeline Usage Guide

This guide provides step-by-step instructions for running the metagenomics pipeline, including setup, dependencies, and detailed description of each processing step.

Note: To streamline the workflow, a single script—Metagenomics_pipeline.sh—is provided to automate the execution of all pipeline steps in sequence. Upon running the script, you will be prompted to choose between two processing strategies:

Option 1: Merge reads first using SeqPrep, followed by trimming.

Option 2: Perform trimming first, followed by merging.

Based on your selection, the corresponding preprocessing and analysis scripts will be executed automatically in the appropriate order.

---

## Prerequisites & Setup

### 1. Directory and File Preparation

- **Download Required Folders**:
  - `FragGeneScan-master`
  - `ribosome`

- **Download Scripts**:
  - Either download all files inside the `Scripts` folder individually, or download the entire `Scripts` folder and run:
    ```bash
    mv Scripts/*.sh .
    ```
    > All scripts must reside in the same directory as your FASTQ files

### 2. Reference Database Setup for MAPseq

- **Create directory and enter it** (use `-p` to avoid errors if directory exists):
  ```bash
  mkdir -p ref-dbs && cd ref-dbs
  ```

- **Download SILVA SSU/LSU databases**:
  ```bash
  wget -nc ftp://ftp.ebi.ac.uk/pub/databases/metagenomics/pipeline-5.0/ref-dbs/silva_ssu-20200130.tar.gz
  wget -nc ftp://ftp.ebi.ac.uk/pub/databases/metagenomics/pipeline-5.0/ref-dbs/silva_lsu-20200130.tar.gz
  ```

- **Extract and clean up archives**:
  ```bash
  tar -xzf silva_ssu-20200130.tar.gz
  tar -xzf silva_lsu-20200130.tar.gz
  rm -f silva_ssu-20200130.tar.gz silva_lsu-20200130.tar.gz  # Optional
  ```

### 3. Environment Setup

- Instead of installing dependencies individually, download the provided `environment.yml` file and run:
  ```bash
  conda env create -f environment.yml --name metagenomics-env # or any name you prefer
  conda activate metagenomics-env
  ```

---

## Pipeline Steps

### 1. Adapter Type Identification

- **Purpose**: Detect and identify adapter sequences present in raw reads (if any).
- **Instructions**:
  - Execute the following in the directory containing your FASTQ files:
    ```bash
    ls *.fastq | parallel -j 4 "fastqc {} -o Fastqc_preprocessing"
    ```
    - `-j`: Number of threads (adjust based on your system).
    - Files must have a `.fastq` extension (modify pattern if needed).
  - Output: `.html` reports (open in browser, see "Adapter Content" section).

---

### 2. Adapter Trimming, Quality Filtering, and Read Merging

You have two options:

#### **Option 1:** Trim adapters and low-quality reads first with Trimmomatic, then merge with Flash.

- **Script**: `merging_trim_qc.sh`
- **Key Parameters**:
  - `ADAPTER_FILE="TruSeq3-PE.fa"`  
    - Download from [Trimmomatic GitHub](https://github.com/usadellab/Trimmomatic/tree/main) after identifying adapter sequence from FastQC.
    - Adjust other parameters as needed within the script (open with `nano filename`).

#### **Option 2:** Merge first with SeqPrep, then trim with Trimmomatic.

- **Script**: `seqprep.sh`
- **Key Parameters**:
  - `ADAPTER_A="GATCGGAAGAGCACACG"`
  - `ADAPTER_B="AGATCGGAAGAGCGTCGT"`
    - Edit these based on adapter sequences found in FastQC report.
    - Trimmomatic parameters are also available in this script.

- **Note**: Both options generate quality reports on all resulting files (trimmed, merged, and trimmed-merged reads).

- **Input for Both Options**: Paired-end raw reads (FASTQ format).

- **Action**: Merges overlapping paired-end reads into single contiguous sequences.

---

### 3. Convert Trimmed-Merged Reads to FASTA

- Use `seqkit` to convert processed reads to FASTA format for subsequent steps.

---

### 4. Homology Search Against Databases

- **Tool**: `cmssearch` (from Infernal package)
- **Purpose**: Search trimmed reads against curated RNA family databases (e.g., Rfam) to identify conserved non-coding sequences.
- **Output**: `.tbl` files (contain coordinates and information on non-coding sequences; later merged into a BED file).

- **Key Parameter in `cms_search_automated.sh`**:
  - `THRESHOLD_METHOD="EVALUE"`  (Options: `"EVALUE"` or `"SCORE"`)
    - **SCORE**: Quality of alignment to the covariance model (CM).
    - **E-value**: Statistical significance of the match.
    - Significant hits: E-value < 0.01 and bit score ≥ 20 bits.
    - Borderline cases: Validate with additional evidence (e.g., secondary structure).

---

### 5. Non-Coding Sequence Masking

- **Purpose**: Replace non-coding sequences (e.g., rRNA, tRNA) with `X` (default) or specified letter for downstream processing.
- **Tool**: `bedtools`
  - Input: BED file (from previous step) and FASTA format query file.

---

### 6. Functional Annotation

- **Purpose**: Predict coding sequences (CDS) from masked sequences, identify mRNA, and translate to amino acid sequences.
- **Tool**: `FragGeneScan`
- **Script**: `FragGeneScan.sh`
- **Key Parameters**:
  - `TRAIN_SET="illumina_10"`  
    - Options:
      - `complete`: Complete genomic sequences/short reads without error
      - `sanger_5`, `sanger_10`: Sanger reads (~0.5% and 1% error rates)
      - `454_5`, `454_10`, `454_30`: 454 pyrosequencing reads (various error rates)
      - `illumina_5`, `illumina_10`: Illumina reads (various error rates)

  - For read length <300, set `-complete=0` (otherwise use 1).

  - Multi-threading is supported via `-thread` parameter.

  - **Error Handling**: Errors are logged; failed samples are tracked.

---

### 7. Extract Non-Coding Sequences as FASTA

- **Purpose**: Use FASTA files and BED coordinates to extract actual coding sequences per sample.
- **Tool**: `bedtools`

---

### 8. Taxonomic Classification

- **Input**: Masked reads, SSU and LSU (small/large ribosomal subunit) FASTA files and their annotations (downloaded in setup).
- **Tool**: `MAPseq` (rRNA-based classification)
- **Output**: Taxonomic profiles in `.otu` files (from phylum to species level).

---

### 9. Visualization of Taxonomic Profiles

- **Extraction**: Use `kraken_reports.sh` to extract relevant data for visualization.
- **Visualization**: Use Krona tool via `korona_plots.sh` to generate interactive visualizations.

---

## Summary

This pipeline automates the processing of metagenomic data from adapter identification and quality control through sequence annotation and taxonomic profiling, culminating in interactive visualization of taxonomic profiles. Key steps and customizable parameters are highlighted for user adjustment based on experimental needs.

For further details on each script, consult the script headers and comments, or open them for editing (e.g., with `nano`).

---
