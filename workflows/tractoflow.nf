/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include {   MULTIQC                 } from '../modules/nf-core/multiqc/main'
include {   paramsSummaryMap        } from 'plugin/nf-validation'
include {   paramsSummaryMultiqc    } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include {   softwareVersionsToYAML  } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include {   methodsDescriptionText  } from '../subworkflows/local/utils_nfcore_tractoflow_pipeline'

// PREPROCESSING
include {   PREPROC_DWI                                               } from '../subworkflows/nf-scil/preproc_dwi/main'
include {   PREPROC_T1                                                } from '../subworkflows/nf-scil/preproc_t1/main'
include {   RECONST_DTIMETRICS as REGISTRATION_FA                     } from '../modules/nf-scil/reconst/dtimetrics/main'
include {   REGISTRATION as T1_REGISTRATION                           } from '../subworkflows/nf-scil/registration/main'
include {   REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_WMPARC      } from '../modules/nf-scil/registration/antsapplytransforms/main'
include {   REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_APARC_ASEG  } from '../modules/nf-scil/registration/antsapplytransforms/main'
include {   ANATOMICAL_SEGMENTATION                                   } from '../subworkflows/nf-scil/anatomical_segmentation/main'

// RECONSTRUCTION
include {   RECONST_FRF        } from '../modules/nf-scil/reconst/frf/main'
include {   RECONST_MEANFRF    } from '../modules/nf-scil/reconst/meanfrf/main'
include {   RECONST_DTIMETRICS } from '../modules/nf-scil/reconst/dtimetrics/main'
include {   RECONST_FODF       } from '../modules/nf-scil/reconst/fodf/main'

// TRACKING
include { TRACKING_PFTTRACKING } from '../modules/nf-scil/tracking/pfttracking/main'
include { TRACKING_LOCALTRACKING } from '../modules/nf-scil/tracking/localtracking/main'

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
    ch_topup_config = Channel.empty()
    ch_bet_template = Channel.empty()

    /* Load topup config if provided */
    if ( params.dwi_susceptibility_filter_config_file ) {
        if ( file(params.dwi_susceptibility_filter_config_file).exists()) {
            ch_topup_config = Channel.fromPath(params.topup_config, checkIfExists: true)
        }
        else {
            ch_topup_config = Channel.from( params.dwi_susceptibility_filter_config_file )
        }
    }

    /* Load bet template */
    ch_bet_template = Channel.fromPath(params.t1_bet_template_t1, checkIfExists: true)
    ch_bet_probability = Channel.fromPath(params.t1_bet_template_probability_map, checkIfExists: true)

    /* Unpack inputs */
    ch_inputs = ch_samplesheet
        .multiMap{ meta, dwi, bval, bvec, sbref, rev_dwi, rev_bval, rev_bvec, rev_sbref, t1, wmparc, aparc_aseg ->
            dwi: [meta, dwi, bval, bvec]
            sbref: [meta, sbref]
            rev_dwi: [meta, rev_dwi, rev_bval, rev_bvec]
            rev_sbref: [meta, rev_sbref]
            t1: [meta, t1]
            wmparc: [meta, wmparc]
            aparc_aseg: [meta, aparc_aseg]
        }

    /* PREPROCESSING */

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
    ch_t1_meta = ch_inputs.t1.map{ it[0] }
    PREPROC_T1(
        ch_inputs.t1,
        ch_t1_meta.combine(ch_bet_template),
        ch_t1_meta.combine(ch_bet_probability),
        Channel.empty(),
        Channel.empty(),
        Channel.empty()
    )

    //
    // MODULE: Run RECONST/DTIMETRICS (REGISTRATION_FA)
    //
    ch_registration_fa = PREPROC_DWI.out.dwi_resample
        .join(PREPROC_DWI.out.bval)
        .join(PREPROC_DWI.out.bvec)
        .join(PREPROC_DWI.out.b0_mask)

    REGISTRATION_FA( ch_registration_fa )

    //
    // SUBWORKFLOW: Run REGISTRATION
    //
    T1_REGISTRATION(
        PREPROC_T1.out.t1_final,
        PREPROC_DWI.out.b0,
        REGISTRATION_FA.out.fa,
        []
    )

    /* SEGMENTATION */

    //
    // MODULE: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_WMPARC)
    //
    TRANSFORM_WMPARC(
        ch_inputs.wmparc
            .filter{ it[1] }
            .join(PREPROC_DWI.out.b0)
            .join(T1_REGISTRATION.out.transfo_image)
            .map{ it[0..2] + [it[3..-1]] }
    )

    //
    // MODULE: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_APARC_ASEG)
    //
    TRANSFORM_APARC_ASEG(
        ch_inputs.aparc_aseg
            .filter{ it[1] }
            .join(PREPROC_DWI.out.b0)
            .join(T1_REGISTRATION.out.transfo_image)
            .map{ it[0..2] + [it[3..-1]] }
    )

    //
    // SUBWORKFLOW: Run ANATOMICAL_SEGMENTATION
    //
    ANATOMICAL_SEGMENTATION(
        T1_REGISTRATION.out.image_warped,
        TRANSFORM_WMPARC.out.warpedimage
            .join(TRANSFORM_APARC_ASEG.out.warpedimage)
    )

    /* RECONSTRUCTION */

    //
    // MODULE: Run RECONST/DTIMETRICS
    //
    ch_dti_metrics = PREPROC_DWI.out.dwi_resample
        .join(PREPROC_DWI.out.bval)
        .join(PREPROC_DWI.out.bvec)
        .join(PREPROC_DWI.out.b0_mask)

    RECONST_DTIMETRICS( ch_dti_metrics )

    //
    // MODULE: Run RECONST/FRF
    //
    ch_reconst_frf = PREPROC_DWI.out.dwi_resample
        .join(PREPROC_DWI.out.bval)
        .join(PREPROC_DWI.out.bvec)
        .join(PREPROC_DWI.out.b0_mask)

    RECONST_FRF( ch_reconst_frf )

    /* Run fiber response aeraging over subjects */
    ch_fiber_response = RECONST_FRF.out.frf
    if ( params.dwi_fodf_fit_use_average_frf ) {
        RECONST_MEANFRF( RECONST_FRF.out.frf.map{ it[1] }.flatten() )
        ch_fiber_response = RECONST_FRF.out.map{ it[0] }
            .combine( RECONST_MEANFRF.out.meanfrf )
    }

    //
    // MODULE: Run RECONST/FODF
    //
    ch_reconst_fodf = PREPROC_DWI.out.dwi_resample
        .join(PREPROC_DWI.out.bval)
        .join(PREPROC_DWI.out.bvec)
        .join(PREPROC_DWI.out.b0_mask)
        .join(RECONST_DTIMETRICS.out.fa)
        .join(RECONST_DTIMETRICS.out.md)
        .join(ch_fiber_response)
    RECONST_FODF( ch_reconst_fodf )

    //
    // MODULE: Run TRACKING/PFTTRACKING
    //
    ch_pft_tracking = ANATOMICAL_SEGMENTATION.out.wm_mask
        .join(ANATOMICAL_SEGMENTATION.out.gm_mask)
        .join(ANATOMICAL_SEGMENTATION.out.csf_mask)
        .join(RECONST_FODF.out.fodf)
        .join(RECONST_DTIMETRICS.out.fa)
    TRACKING_PFTTRACKING( ch_pft_tracking )

    //
    // MODULE: Run TRACKING/LOCALTRACKING
    //
    ch_local_tracking = ANATOMICAL_SEGMENTATION.out.wm_mask
        .join(RECONST_FODF.out.fodf)
        .join(RECONST_DTIMETRICS.out.fa)
    TRACKING_LOCALTRACKING( ch_local_tracking )

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
