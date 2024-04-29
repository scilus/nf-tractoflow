/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { MULTIQC                 } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap        } from 'plugin/nf-validation'
include { paramsSummaryMultiqc    } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML  } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText  } from '../subworkflows/local/utils_nfcore_tractoflow_pipeline'

// PREPROCESSING
include { PREPROC_DWI                                              } from '../subworkflows/nf-scil/preproc_dwi/main'
include { PREPROC_T1                                               } from '../subworkflows/nf-scil/preproc_t1/main'
include { RECONST_DTIMETRICS as REGISTRATION_FA                    } from '../modules/nf-scil/reconst/dtimetrics/main'
include { REGISTRATION as T1_REGISTRATION                          } from '../subworkflows/nf-scil/registration/main'
include { REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_FREESURFER } from '../modules/nf-scil/registration/antsapplytransforms/main'
include { ANATOMICAL_SEGMENTATION                                  } from '../subworkflows/nf-scil/anatomical_segmentation/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow TRACTOFLOW {

    take:
    ch_samplesheet // channel: samplesheet read in from --input

    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()
    ch_topup_config = null
    ch_bet_template = Channel.empty()

    ch_samplesheet.view()

    /* Load topup config if provided */
    if ( params.topup_config ) ch_topup_config = Channel.fromPath(
        params.topup_config, checkIfExists: true)

    /* Load bet template */
    ch_bet_template = Channel.fromPath(params.t1_bet_template, checkIfExists: true)
    ch_bet_probability = Channel.fromPath(params.t1_bet_probability, checkIfExists: true)

    /* Unpack inputs */
    ch_inputs = ch_samplesheet
        .multiMap{ id, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg ->
            dwi: [[id: id], dwi, bval, bvec],
            sbref: [[id: id], sbref],
            rev_dwi: [[id: id], rev_dwi, rev_bval, rev_bvec],
            rev_sbref: [[id: id], rev_sbref],
            t1: [[id: id], t1],
            parc: [[id: id], wmparc, aparc_aseg]
        }

    //
    // SUBWORKFLOW: Run PREPROC_DWI
    //
    PREPROC_DWI(
        ch_inputs.dwi, ch_inputs.rev_dwi,
        ch_inputs.sbref, ch_inputs.rev_sbref,
        ch_topup_config
    )

    //
    // SUBWORKFLOW: Run PREPROC_T1
    //
    PREPROC_T1(
        ch_inputs.t1,
        ch_bet_template,
        ch_bet_probability,
        [], [], []
    )

    //
    // MODULE: Run RECONST/DTIMETRICS (REGISTRATION_FA)
    //
    ch_registration_fa = PREPROC_DWI.out.dwi_resample
        .join(PREPROC_DWI.out.bval)
        .join(PREPROC_DWI.out.bvec)
        .join(PREPROC_DWI.out.b0_mask)

    REGISTRATION_FA(
        ch_registration_fa
    )

    //
    // SUBWORKFLOW: Run REGISTRATION
    //
    T1_REGISTRATION(
        PREPROC_T1.out.t1_final,
        PREPROC_DWI.out.b0,
        REGISTRATION_FA.out.fa,
        []
    )

    //
    // MODULE: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_FREESURFER)
    //

    TRANSFORM_FREESURFER(
        PREPROC_DWI.out.b0,
        T1_REGISTRATION.out.transfo_image
    )

    //
    // SUBWORKFLOW: Run ANATOMICAL_SEGMENTATION
    //
    ANATOMICAL_SEGMENTATION(
        T1_REGISTRATION.out.image_warped,
        ch_inputs.parc
    )

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(storeDir: "${params.outdir}/pipeline_info", name: 'nf_core_pipeline_software_mqc_versions.yml', sort: true, newLine: true)
        .set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config                     = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config              = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
    ch_multiqc_logo                       = params.multiqc_logo ? Channel.fromPath(params.multiqc_logo, checkIfExists: true) : Channel.empty()
    summary_params                        = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary                   = Channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(methodsDescriptionText(ch_multiqc_custom_methods_description))
    ch_multiqc_files                      = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files                      = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files                      = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: false))

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
