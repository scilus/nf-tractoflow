//
// Subworkflow with functionality specific to the scilus/sf-tractomics pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'
include { fromBIDS                  } from 'plugin/nf-bids'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    _monochrome_logs  // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    input             //  string: Path to input directory or input samplesheet
    fs                //  string: Path to FreeSurfer directory
    help              // boolean: Display help message and exit
    help_full         // boolean: Show the full help message
    show_hidden       // boolean: Show hidden parameters in the help message

    main:

    ch_versions = channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        false   // Reinstate when/if we use conda/mamba :
                // workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    command = "nextflow run ${workflow.manifest.name} -profile <docker/singularity/.../institute> --input samplesheet.csv --outdir <OUTDIR>"
    before_text = """
-\033[2m----------------------------------------------------------------------------------\033[0m-
   \033[0;32m      _---~~(~~-_.\033[0m
  \033[0;32m    _{        )   )\033[0m
  \033[0;32m  ,   ) -~~- ( ,-' )_\033[0m
  \033[0;32m (  `-,_..`., )-- '_,)\033[0m
  \033[0;32m( ` _)  (  -~( -_ `,  }\033[0m
  \033[0;32m(_-  _  ~_-~~~~`,  ,' )\033[0m
  \033[0;32m  `~ -^(    __;-,((()))\033[0m
  \033[0;32m        ~~~~ {_ -_(())\033[0m
  \033[0;32m               `\\  }\033[0m
  \033[0;32m                 { }\033[0m

 \033[0;34m  __  ___       ___  __   __   __  ___  __   __       __   __   \033[0m
 \033[0;34m (__  |__  ___   |  |__) |__| |     |  |  | |\\/| |   /    (__   \033[0m
 \033[0;34m ___) |          |  |  \\ |  | |__   |  |__| |  | |   \\__  ___)  \033[0m

 \033[0;35m  scilus/sf-tractomics ${workflow.manifest.version}\033[0m
-\033[2m----------------------------------------------------------------------------------\033[0m-
    """
    after_text = """${workflow.manifest.doi ? "\n* The pipeline\n" : ""}${workflow.manifest.doi.tokenize(",").collect { doi -> "    https://doi.org/${doi.trim().replace('https://doi.org/','')}"}.join("\n")}${workflow.manifest.doi ? "\n" : ""}
    * The nf-neuro project
        https://scilus.github.io/nf-neuro

    * The nf-core framework
        https://doi.org/10.1038/s41587-020-0439-x

    * Software dependencies
        https://github.com/scilus/sf-tractomics/blob/master/CITATIONS.md
    """

    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null,
        help,
        help_full,
        show_hidden,
        before_text,
        after_text,
        command,
        null
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    if (workflow.profile.contains('gpu') && !params.gpu_type) {
        error "When using the 'gpu' profile, you must specify --gpu_type (e.g. h100 or a100)."
    }

    //
    // Create channel from input file provided through params.input
    //
    if (input) {
        log.info "Input ${input}"
        //
        // params.input is either a BIDS compliant directory or a samplesheet
        //   - if directory, we assume it is BIDS
        //   - everything else is a samplesheet
        //
        if (file(input).isDirectory()) {
            log.info "Input is a BIDS directory. Using nf-bids plugin to parse the BIDS dataset."
            // ** To support comma separated participant labels and list ** //
            def participant_ids = params.participant_label ?
                params.participant_label instanceof String ?
                params.participant_label.tokenize(",") :
                params.participant_label : []

            ch_inputs = channel.fromBIDS(
                input,
                "$projectDir/assets/nf-bids_config.yml",
                [flatten_output: true,
                unpack_json_sidecar: true]
            )
            .filter { item -> participant_ids.isEmpty() || item.meta.subject in participant_ids }
            .flatMap { item ->
                def id = item.meta.subject
                def ses = item.meta.session == "NA" ? null : item.meta.session

                // If harmonization is enabled, fetch age, sex and site.
                // Flag subjects with missing information and exit.
                if (params.harmonization_reference) {
                    if (!item.meta.age || !item.meta.sex || !item.meta.site) {
                        error "ERROR: Missing age, sex or site for participant ${id}${ses ? " and session " + ses : ""} in BIDS dataset. Please validate."
                    }
                }

                // ** Instantiate a variable that will collect prints related to BIDS file matching ** //
                // ** to be printed in a log file later                                             ** //
                def logs = []

                // DWI and associated files
                def dwi = item.dwi?.nii ?: []
                def dwi_json = item.dwi?.json ?: []
                def dwi_bval = item.dwi?.bval ?: []
                def dwi_bvec = item.dwi?.bvec ?: []

                // DWI AP/PA
                def dwi_ap = item.dwi_full?.ap?.nii ?: []
                def dwi_ap_json = item.dwi_full?.ap?.json ?: []
                def dwi_ap_bval = item.dwi_full?.ap?.bval ?: []
                def dwi_ap_bvec = item.dwi_full?.ap?.bvec ?: []
                def dwi_pa = item.dwi_full?.pa?.nii ?: []
                def dwi_pa_json = item.dwi_full?.pa?.json ?: []
                def dwi_pa_bval = item.dwi_full?.pa?.bval ?: []
                def dwi_pa_bvec = item.dwi_full?.pa?.bvec ?: []

                // ** Figuring out which DWI to use for the pipeline ** //
                // ** dwi should be mutually exclusive with dwi_ap and dwi_pa ** //
                // ** but taking the PA/AP if available **//
                def use_ap_pa = dwi_ap || dwi_pa
                if ( dwi && use_ap_pa ) {
                    logs << "[${id}${ses ? "/" + ses : ""}] Both single DWI and AP/PA DWI found. Using AP/PA DWI " +
                            "for processing. Use .bidsignore to override."
                }

                // Sbref
                def sbref = item.sbref?.nii ?: []
                def sbref_json = item.sbref?.json ?: []

                // Sbref AP/PA
                def sbref_ap = item.sbref_full?.ap?.nii ?: []
                def sbref_ap_json = item.sbref_full?.ap?.json ?: []
                def sbref_pa = item.sbref_full?.pa?.nii ?: []
                def sbref_pa_json = item.sbref_full?.pa?.json ?: []

                // EPI
                def epi = item.epi?.nii ?: []
                def epi_json = item.epi?.json ?: []

                // EPI AP/PA
                def epi_ap = item.epi_full?.ap?.nii ?: []
                def epi_ap_json = item.epi_full?.ap?.json ?: []
                def epi_pa = item.epi_full?.pa?.nii ?: []
                def epi_pa_json = item.epi_full?.pa?.json ?: []

                // T1w
                // ** Note: we don't need the JSON files for T1w ** //
                def t1w = item.T1w?.nii ?: []

                if ( t1w && t1w.size() > 1 ) {
                    logs << "[${id}${ses ? "/" + ses : ""}] Multiple T1w images found. Using the last one for processing. Use .bidsignore to override."
                    t1w = t1w[-1]
                }
                else if ( t1w ){
                    t1w = t1w[0]
                }

                // Get Freesurfer parcellations if exists
                def (aparc_aseg, wmparc, fs_log) = getFreeSurferParcellations(fs, id, ses)
                logs << fs_log

                // ** Starting with AP/PA, look if there are multiple runs ** //
                def files = []
                if ( !t1w ) {
                    // No T1w
                    log.warn "No T1w found for this subject id: ${id} ${ses ? "and session: " + ses : ""}. Skipping."
                }
                else if ( use_ap_pa ) {
                    // ** We might get only one of the two, so assume AP by default, if absent, use PA ** //
                    def primary_nii = []
                    def primary_json = []
                    def primary_bval = []
                    def primary_bvec = []
                    def reverse_nii = []
                    def reverse_json = []
                    def reverse_bval = []
                    def reverse_bvec = []
                    if (dwi_ap) {
                        primary_nii = normalizeToList(dwi_ap)
                        primary_json = normalizeToList(dwi_ap_json)
                        primary_bval = normalizeToList(dwi_ap_bval)
                        primary_bvec = normalizeToList(dwi_ap_bvec)
                        reverse_nii = normalizeToList(dwi_pa)
                        reverse_json = normalizeToList(dwi_pa_json)
                        reverse_bval = normalizeToList(dwi_pa_bval)
                        reverse_bvec = normalizeToList(dwi_pa_bvec)
                    } else {
                        primary_nii = normalizeToList(dwi_pa)
                        primary_json = normalizeToList(dwi_pa_json)
                        primary_bval = normalizeToList(dwi_pa_bval)
                        primary_bvec = normalizeToList(dwi_pa_bvec)
                        reverse_nii = normalizeToList(dwi_ap)
                        reverse_json = normalizeToList(dwi_ap_json)
                        reverse_bval = normalizeToList(dwi_ap_bval)
                        reverse_bvec = normalizeToList(dwi_ap_bvec)
                    }
                    primary_nii.eachWithIndex { nii, idx ->
                        def run_id = extractRunFromFilename(nii) ?: (primary_nii.size() > 1 ? "${idx + 1}" : "")
                        def rev_idx = findMatchingReverseFile(nii, reverse_nii)
                        // ** Before mixing the AP/PA, check if the PhaseEncodingDirection are opposite ** //
                        def pe_check = [matched: true, warnings: [], pe: null]
                        if (rev_idx != null) {
                            pe_check = areOppositePhaseEncoding(pe_check, primary_json[idx], reverse_json[rev_idx])
                            if (!pe_check.matched) {
                                logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] ${pe_check.warnings.join(" ")}"
                            }
                        }

                        def readout = primary_json[idx]?.TotalReadoutTime ?: primary_json[idx]?.EstimatedTotalReadoutTime ?: params.dwi_susceptibility_readout

                        // ** Finding possible sbref and epi candidates for this DWI run ** //
                        def sbref_candidates = []
                        [
                            [sbref_ap, sbref_ap_json, "AP"], [sbref_pa, sbref_pa_json, "PA"], [sbref, sbref_json, "NA"]
                        ].each { group ->
                            def nii_list = normalizeToList(group[0])
                            def json_list = normalizeToList(group[1])
                            nii_list.eachWithIndex { snii, sidx ->
                                sbref_candidates << [nii: snii, json: json_list[sidx], direction: group[2]]
                            }
                        }
                        def epi_candidates = []
                        [
                            [epi_ap, epi_ap_json, "AP"], [epi_pa, epi_pa_json, "PA"], [epi, epi_json, "NA"]
                        ].each { group ->
                            def nii_list = normalizeToList(group[0])
                            def json_list = normalizeToList(group[1])
                            nii_list.eachWithIndex { enii, eidx ->
                                epi_candidates << [nii: enii, json: json_list[eidx], direction: group[2]]
                            }
                        }

                        // ** Inspecting the JSON metadata to find matches ** //
                        def sbref_match = []
                        sbref_candidates.each { candidate ->
                            def match = matchFilesToDWI(
                                primary_json[idx],
                                nii,
                                rev_idx ? reverse_json[rev_idx] : [:],
                                rev_idx ? reverse_nii[rev_idx] : null,
                                candidate.json       // JSON file
                            )

                            if (match.matched) {
                                sbref_match << [nii: candidate.nii, json: candidate.json]
                            }
                            match.warnings.each { w ->
                                logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] WARN (sbref) ${w}"
                            }
                        }

                        def epi_match = []
                        epi_candidates.each { candidate ->
                            def match = matchFilesToDWI(
                                primary_json[idx],
                                nii,
                                rev_idx ? reverse_json[rev_idx] : [:],
                                rev_idx ? reverse_nii[rev_idx] : null,
                                candidate.json       // JSON file
                            )

                            if (match.matched) {
                                epi_match << [nii: candidate.nii, json: candidate.json]
                            }
                            match.warnings.each { w ->
                                logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] WARN (epi) ${w}"
                            }
                        }

                        if (!sbref_match && !epi_match) {
                            logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] No matching sbref or epi found for this DWI run."
                        }

                        // ** Organize the matched sbref/epi files by alignment with main DWI PE ** //
                        def sbref_split = splitByPEDirection(sbref_match, primary_json[idx])
                        def epi_split = splitByPEDirection(epi_match, primary_json[idx])

                        files << [
                            [id: id,
                            session: ses ?: "",
                            run: run_id,
                            readout: readout,
                            pe: pe_check.pe,
                            age: item.meta.age,
                            sex: item.meta.sex ? (item.meta.sex.toString().trim().toLowerCase() in ['m', 'male', '1'] ? 1 : item.meta.sex.toString().trim().toLowerCase() in ['f', 'female', '2'] ? 2 : 1) : 1,
                            handedness: item.meta.handedness ? (item.meta.handedness?.toLowerCase().contains("r") ? 1 : item.meta.handedness?.toLowerCase().contains("l") ? 2 : 1) : 1,
                            disease: item.meta.disease ?: "HC",
                            site: item.meta.site],
                            t1w,
                            wmparc,
                            aparc_aseg,
                            [nii, primary_bval[idx], primary_bvec[idx]],
                            (rev_idx != null) ? [reverse_nii[rev_idx], reverse_bval[rev_idx], reverse_bvec[rev_idx]] : [],
                            sbref_split?.same?.find()?.nii ?: epi_split?.same?.find()?.nii ?: [],
                            sbref_split?.opposite?.find()?.nii ?: epi_split?.opposite?.find()?.nii ?: [],
                            []
                        ]
                    }
                }
                else if (dwi) {
                    // ** In this case, we have a DWI without the dir- entity, but we may have runs ** //
                    def dwi_list = normalizeToList(dwi)
                    def dwi_json_list = normalizeToList(dwi_json)
                    def dwi_bval_list = normalizeToList(dwi_bval)
                    def dwi_bvec_list = normalizeToList(dwi_bvec)

                    dwi_list.eachWithIndex { nii, idx ->
                        def run_id = extractRunFromFilename(nii) ?: (dwi_list.size() > 1 ? "${idx + 1}" : "")
                        def readout = dwi_json_list[idx]?.TotalReadoutTime ?: dwi_json_list[idx]?.EstimatedTotalReadoutTime ?: params.dwi_susceptibility_readout
                        def axisMap = [j: "y"]
                        def pe = axisMap[dwi_json_list[idx]?.PhaseEncodingDirection]

                        // ** Finding possible sbref and epi candidates for this DWI run ** //
                        def sbref_candidates = []
                        [
                            [sbref_ap, sbref_ap_json, "AP"], [sbref_pa, sbref_pa_json, "PA"], [sbref, sbref_json, "NA"]
                        ].each { group ->
                            def nii_list = normalizeToList(group[0])
                            def json_list = normalizeToList(group[1])
                            nii_list.eachWithIndex { snii, sidx ->
                                sbref_candidates << [nii: snii, json: json_list[sidx], direction: group[2]]
                            }
                        }

                        def epi_candidates = []
                        [
                            [epi_ap, epi_ap_json, "AP"], [epi_pa, epi_pa_json, "PA"], [epi, epi_json, "NA"]
                        ].each { group ->
                            def nii_list = normalizeToList(group[0])
                            def json_list = normalizeToList(group[1])
                            nii_list.eachWithIndex { enii, eidx ->
                                epi_candidates << [nii: enii, json: json_list[eidx], direction: group[2]]
                            }
                        }

                        // ** Now matching them via the metadata ** //
                        def sbref_match = []
                        sbref_candidates.each { candidate ->
                            def match = matchFilesToDWI(
                                dwi_json_list[idx],
                                nii,
                                [:],
                                null,
                                candidate.json       // JSON file
                            )

                            if (match.matched) {
                                sbref_match << [nii: candidate.nii, json: candidate.json]
                            }
                            match.warnings.each { w ->
                                logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] WARN (sbref) ${w}"
                            }
                        }

                        def epi_match = []
                        epi_candidates.each { candidate ->
                            def match = matchFilesToDWI(
                                dwi_json_list[idx],
                                nii,
                                [:],
                                null,
                                candidate.json  // JSON file
                            )

                            if (match.matched) {
                                epi_match << [nii: candidate.nii, json: candidate.json]
                            }
                            match.warnings.each { w ->
                                logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] WARN (epi) ${w}"
                            }
                        }

                        if (!sbref_match && !epi_match) {
                            logs << "[${id}${ses ? "/" + ses : ""}${run_id ? '/run-' + run_id : ''}] No matching sbref or epi found for this DWI run."
                        }

                        // ** Organize by PE direction matching the PE of the main DWI file ** //
                        def sbref_split = splitByPEDirection(sbref_match, dwi_json_list[idx])
                        def epi_split = splitByPEDirection(epi_match, dwi_json_list[idx])

                        files << [
                            [id: id,
                            session: ses ?: "",
                            run: run_id,
                            readout: readout,
                            pe: pe,
                            age: item.meta.age,
                            sex: item.meta.sex ? (item.meta.sex.toString().trim().toLowerCase() in ['m', 'male', '1'] ? 1 : item.meta.sex.toString().trim().toLowerCase() in ['f', 'female', '2'] ? 2 : 1) : 1,
                            handedness: item.meta.handedness ? (item.meta.handedness?.toLowerCase().contains("r") ? 1 : item.meta.handedness?.toLowerCase().contains("l") ? 2 : 1) : 1,
                            disease: item.meta.disease ?: "HC",
                            site: item.meta.site],
                            t1w,
                            wmparc,
                            aparc_aseg,
                            [nii, dwi_bval_list[idx], dwi_bvec_list[idx]],
                            [],
                            sbref_split?.same?.find()?.nii ?: epi_split?.same?.find()?.nii ?: [],
                            sbref_split?.opposite?.find()?.nii ?: epi_split?.opposite?.find()?.nii ?: [],
                            []
                        ]
                    }
                }
                else {
                    // No DWI
                    log.warn "No DWI found for this subject id: ${id} ${ses ? "and session: " + ses : ""}. Skipping."
                }

                // ** Save the logs into ${params.outdir}/pipeline_info/BIDS_logs.txt ** //
                file("${params.outdir}/pipeline_info/BIDS_logs.txt") << logs.join("\n") + "\n"

                // Add a check that b-values are within the params.dti_max_shell_value and params.fodf_min_shell_value, and if not, throw an error.
                if ( files[0] != null && files[0][4] && !params.dti_shells && !params.fodf_shells && ( params.run_pft_tracking || params.run_local_tracking ) ) {

                    def bvals = file(files[0][4][1]).text.trim().split(/\s+/).findAll { it -> it }.collect { it -> it as Double }.toSet()
                        .findAll { it -> !(it >= 0 - params.b0_thr_extract_b0) || !(it <= 0 + params.b0_thr_extract_b0) }

                    // Check if any values fits the threshold for DTI fitting (shells under the threshold)
                    def belowDTI = bvals.findAll { it -> it <= params.dti_max_shell_value }
                    if ( belowDTI.size() == 0) {
                        error "ERROR: No b-values are below the dti_max_shell_value threshold of ${params.dti_max_shell_value} for subject ${id}. " +
                            "Current protocol (excluding b0s) contains the following shells: ${bvals.join(', ')}. " +
                            "Please check your acquisition protocol and provide the shells to use for DTI fitting using --dti_shells. " +
                            "Alternatively, you can increase this threshold using --dti_max_shell_value."
                    }

                    // Check if any values fits the threshold for fODF fitting (shells over the threshold)
                    def aboveFODF = bvals.findAll { it -> it >= params.fodf_min_shell_value }
                    if ( aboveFODF.size() == 0) {
                        error "ERROR: No b-values are above the fodf_min_shell_value threshold of ${params.fodf_min_shell_value} for subject ${id}. " +
                            "Current protocol (excluding b0s) contains the following shells: ${bvals.join(', ')}. " +
                            "Please check your acquisition protocol and provide the shells to use for fODF fitting using --fodf_shells. " +
                            "Alternatively, you can decrease this threshold using --fodf_min_shell_value."
                    }
                }
                return files
            }
        }
        else {
            // samplesheet
            log.info "Input ${input} is a samplesheet. Using nf-schema plugin to parse the samplesheet."
            ch_inputs = channel
                .fromList(samplesheetToList(input, "${projectDir}/assets/schema_input.json"))
                .map{
                    meta, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg, lesion ->
                        return [
                            meta,
                            t1,
                            wmparc ?: [],
                            aparc_aseg ?: [],
                            [dwi, bval, bvec],
                            rev_dwi ? [rev_dwi, rev_bval, rev_bvec] : [],
                            sbref ?: [],
                            rev_sbref ?: [],
                            lesion ?: []
                        ]
                }
        }
    }

    ch_inputs.ifEmpty { error "ERROR: No valid input files found. Please check your input directory or samplesheet." }

    emit:
        inputs          = ch_inputs
        versions        = ch_versions
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications
    multiqc_report  //  string: Path to MultiQC report

    main:
    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    def multiqc_reports = multiqc_report.toList()

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(
                summary_params,
                email,
                email_on_fail,
                plaintext_email,
                outdir,
                monochrome_logs,
                multiqc_reports.getVal(),
            )
        }

        completionSummary(monochrome_logs)
    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to troubleshooting docs: https://nf-co.re/docs/usage/troubleshooting"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/


//
// Function to format a list from null, string, or list.
//
def normalizeToList(value) {
    if (value == null) return []
    if (value instanceof List) return value
    return [value]
}

//
// Function to extract run number from a BIDS filename.
//
def extractRunFromFilename(filepath) {
    def filename = filepath instanceof Path ? filepath.name : filepath.toString().split('/')[-1]
    def matcher = (filename =~ /run-([a-zA-Z0-9]+)/)
    return matcher ? matcher[0][1] : null
}
//
// Function to find the matching reverse file in the case of DWI AP/PA
//
def findMatchingReverseFile(primaryFile, List reverseList) {
    if (!reverseList) return null

    def primaryRun = extractRunFromFilename(primaryFile)

    // 1. match by run entity first
    if (primaryRun) {
        def match = reverseList.findIndexOf { rev ->
            extractRunFromFilename(rev) == primaryRun
        }
        if (match >= 0) return match
    }

    // 2. If reverse has only one file, use it
    if (reverseList.size() == 1) return 0

    // 3. nothing to match at this point
    return null
}

//
// Function to assess whether phase encoding direction are opposite for a pair of JSON sidecar files
//
def areOppositePhaseEncoding(Map results, Map json1, Map json2) {
    def pe1 = json1?.PhaseEncodingDirection
    def pe2 = json2?.PhaseEncodingDirection

    if (!pe1 || !pe2) {
        results.warnings << "Missing PhaseEncodingDirection in one of the JSON sidecar files. Cannot determine if they are opposite."
        results.matched = false
        return results
    }

    // ** Currently only support j/j- pair ** //
    def axis1 = pe1.replaceAll("-", "")
    def axis2 = pe2.replaceAll("-", "")
    if (axis1 != axis2) {
        results.warnings << "PhaseEncodingDirection axes do not match: ${pe1} vs ${pe2}. Cannot determine if they are opposite."
        results.matched = false
    }

    def neg1 = pe1.contains("-")
    def neg2 = pe2.contains("-")
    results.matched = (neg1 != neg2) ? true : false

    // ** Convert j/j- into y/y- for clarity ** //
    def axisMap = [j: "y"]
    results.pe = axisMap[axis1]
    if (results.pe == null) {
        results.warnings << "PhaseEncodingDirection axes are not j/j- pair: ${pe1} vs ${pe2}. Cannot determine if they are opposite."
        results.matched = false
    }

    return results
}

//
// Function to match sbref and epi files to DWI
//
def matchFilesToDWI(Map dwiJson, dwiFilename, Map revJson, revFilename, Map assocJson) {
    def result = [matched: false, warnings: []]

    def dwiName = (dwiFilename instanceof Path ? dwiFilename.name :
                    dwiFilename.toString().split('/')[-1])
    def revName = revFilename?.with {
        it instanceof Path ? it.name : it.toString().split('/')[-1]}

    // Trying to find a match between B0FieldSource and B0FieldIdentifier
    def dwiFieldSource = dwiJson?.B0FieldSource
    def assocFieldId = assocJson?.B0FieldIdentifier

    if (dwiFieldSource && assocFieldId) {
        if (normalizeToList(dwiFieldSource).intersect(normalizeToList(assocFieldId))) {
            result.matched = true
        } else {
            result.warnings << "B0FieldSource and B0FieldIdentifier do not match: ${dwiFieldSource} vs ${assocFieldId}. Cannot determine if they are opposite."
            return result
        }
    }

    // Checking the reverse association in case it happens
    def dwiFieldId = dwiJson?.B0FieldIdentifier
    def assocFieldSource = assocJson?.B0FieldSource

    if (dwiFieldId && assocFieldSource) {
        if (normalizeToList(dwiFieldId).intersect(normalizeToList(assocFieldSource))) {
            result.matched = true
        } else {
            result.warnings << "B0FieldIdentifier and B0FieldSource do not match: ${dwiFieldId} vs ${assocFieldSource}. Cannot determine if they are opposite."
            return result
        }
    }

    // Check in the reverse DWI file, if present, for B0FieldSource and B0FieldIdentifier
    if (revJson) {
        def revFieldSource = revJson?.B0FieldSource
        def revFieldId = revJson?.B0FieldIdentifier

        if (revFieldSource && assocFieldId) {
            if (normalizeToList(revFieldSource).intersect(normalizeToList(assocFieldId))) {
                result.matched = true
            } else {
                result.warnings << "Reverse B0FieldSource and B0FieldIdentifier do not match: ${revFieldSource} vs ${assocFieldId}. Cannot determine if they are opposite."
                return result
            }
        }

        if (revFieldId && assocFieldSource) {
            if (normalizeToList(revFieldId).intersect(normalizeToList(assocFieldSource))) {
                result.matched = true
            } else {
                result.warnings << "Reverse B0FieldIdentifier and B0FieldSource do not match: ${revFieldId} vs ${assocFieldSource}. Cannot determine if they are opposite."
                return result
            }
        }
    }

    // If no B0Field* are present, check for IntendedFor
    def intendedFor = assocJson?.IntendedFor
    if (intendedFor) {
        def matches = normalizeToList(intendedFor).any { target ->
            def targetName = target.toString().replaceAll("^bids::", "").split('/')[-1]
            targetName == dwiName || targetName == revName
        }

        if ( matches ) {
            result.matched = true
        } else {
            return result
        }
    }
    return result
}


//
// Function sort if matched sbref/epi files are the same direction as the main DWI or not.
//
def splitByPEDirection(List matches, Map dwiJson) {
    def dwiPE = dwiJson?.PhaseEncodingDirection
    def samePE = []
    def oppositePE = []

    matches.each { m ->
        def assocPE = m.json?.PhaseEncodingDirection
        if (!dwiPE || !assocPE) {
            // Can't determine, so put in oppositePE for safety
            oppositePE << m
        } else if (arePEDirectionOpposite(dwiPE, assocPE)) {
            oppositePE << m
        } else {
            samePE << m
        }
    }
    return [same: samePE, opposite: oppositePE]
}

//
// Small function to check if two PE strings are in the opposite direction
//
def arePEDirectionOpposite(String pe1, String pe2) {
    def axis1 = pe1.replaceAll("-", "")
    def axis2 = pe2.replaceAll("-", "")
    if (axis1 != axis2) return false
    return pe1.contains("-") != pe2.contains("-")
}

//
// Get file from derivatives freesurfer
//
def getFreeSurferParcellations(fs_dir, id, ses=null) {

    def fs_log = []

    if (!fs_dir) {
        fs_log << "fs_dir is null"
        return [null, null, fs_log]
    }

    def fs_path = file(fs_dir)

    // Candidate FreeSurfer subject directory names
    def candidates = []

    if (ses) {
        candidates << "${id}_${ses}"
    }

    candidates << "${id}"
    fs_log << "Candidates: ${candidates}\n"

    // fs_dir points to a SUBJECTS_DIR containing all Freesurfer subjects
    fs_log << "Looking for FreeSurfer subject directory in: ${fs_path}"
    def subject_dir = candidates
        .collect { it -> file("${fs_path}/${it}") }
        .find { it -> it.exists() }

    if (subject_dir) {
        fs_log << "Found FreeSurfer subject directory: ${subject_dir}"
    }
    else {
        fs_log << "No Freesurfer subject directory found in: ${fs_path}"
    }

    if (!subject_dir) {
        return [null, null, fs_log]
    }

    def aparc_aseg = file("${subject_dir}/mri/aparc+aseg.mgz")
    def wmparc = file("${subject_dir}/mri/wmparc.mgz")
    fs_log << "aparc+aseg.mgz exists: ${aparc_aseg.exists()}"
    fs_log << "wmparc.mgz exists: ${wmparc.exists()}"

    return [
        aparc_aseg.exists() ? aparc_aseg : null,
        wmparc.exists() ? wmparc : null,
        fs_log
    ]
}

//
// Validate channels from input samplesheet
//
def validateInputSamplesheet(input) {
    return input
}

//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "MultiQC (Ewels et al. 2016)",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
            "<li>Ewels, P., Magnusson, M., Lundin, S., & Käller, M. (2016). MultiQC: summarize analysis results for multiple tools and samples in a single report. Bioinformatics , 32(19), 3047–3048. doi: /10.1093/bioinformatics/btw354</li>"
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familiar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}
