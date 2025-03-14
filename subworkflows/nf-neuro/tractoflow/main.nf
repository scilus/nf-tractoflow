
// PREPROCESSING
include {   PREPROC_DWI                                               } from '../preproc_dwi/main'
include {   PREPROC_T1                                                } from '../preproc_t1/main'
include {   RECONST_DTIMETRICS as REGISTRATION_FA                     } from '../../../modules/nf-neuro/reconst/dtimetrics/main'
include {   REGISTRATION as T1_REGISTRATION                           } from '../registration/main'
include {   REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_WMPARC      } from '../../../modules/nf-neuro/registration/antsapplytransforms/main'
include {   REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_APARC_ASEG  } from '../../../modules/nf-neuro/registration/antsapplytransforms/main'
include {   REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_LESION_MASK } from '../../../modules/nf-neuro/registration/antsapplytransforms/main'
include {   REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_BRAINMASK   } from '../../../modules/nf-neuro/registration/antsapplytransforms/main'
include {   ANATOMICAL_SEGMENTATION                                   } from '../anatomical_segmentation/main'

// RECONSTRUCTION
include {   RECONST_FRF        } from '../../../modules/nf-neuro/reconst/frf/main'
include {   RECONST_MEANFRF    } from '../../../modules/nf-neuro/reconst/meanfrf/main'
include {   RECONST_DTIMETRICS } from '../../../modules/nf-neuro/reconst/dtimetrics/main'
include {   RECONST_FODF       } from '../../../modules/nf-neuro/reconst/fodf/main'

// TRACKING
include { TRACKING_PFTTRACKING   } from '../../../modules/nf-neuro/tracking/pfttracking/main'
include { TRACKING_LOCALTRACKING } from '../../../modules/nf-neuro/tracking/localtracking/main'


// ** UTILITY FUNCTIONS ** //

def group_frf ( label, ch_frf ) {
    return ch_frf
        .map{ _meta, frf -> frf }
        .flatten()
        .map{ frf_list -> [label, frf_list] }
}


workflow TRACTOFLOW {
    take:
        ch_dwi              // channel : [required] meta, dwi, bval, bvec
        ch_t1               // channel : [required] meta, t1
        ch_sbref            // channel : [optional] meta, sbref
        ch_rev_dwi          // channel : [optional] meta, rev_dwi, rev_bval, rev_bvec
        ch_rev_sbref        // channel : [optional] meta, rev_sbref
        ch_wmparc           // channel : [optional] meta, wmparc
        ch_aparc_aseg       // channel : [optional] meta, aparc_aseg
        ch_topup_config     // channel : [optional] topup_config
        ch_bet_template     // channel : [optional] meta, bet_template
        ch_bet_probability  // channel : [optional] meta, bet_probability
        ch_lesion_mask      // channel : [optional] meta, lesion_mask
    main:

        ch_versions = Channel.empty()

        /* PREPROCESSING */

        //
        // SUBWORKFLOW: Run PREPROC_DWI
        //
        PREPROC_DWI(
            ch_dwi,
            ch_rev_dwi,
            ch_sbref,
            ch_rev_sbref,
            ch_topup_config
        )
        ch_versions = ch_versions.mix(PREPROC_DWI.out.versions.first())

        //
        // SUBWORKFLOW: Run PREPROC_T1
        //
        PREPROC_T1(
            ch_t1,
            ch_bet_template,
            ch_bet_probability,
            Channel.empty(),
            Channel.empty(),
            Channel.empty(),
            Channel.empty()
        )
        ch_versions = ch_versions.mix(PREPROC_T1.out.versions.first())

        /* RECONSTRUCTION - PART I - doesn't need anatomy */

        //
        // MODULE: Run RECONST/DTIMETRICS
        //
        ch_dti_metrics = PREPROC_DWI.out.dwi
            .join(PREPROC_DWI.out.bval)
            .join(PREPROC_DWI.out.bvec)
            .join(PREPROC_DWI.out.b0_mask)

        RECONST_DTIMETRICS( ch_dti_metrics )
        ch_versions = ch_versions.mix(RECONST_DTIMETRICS.out.versions.first())


        //
        // SUBWORKFLOW: Run REGISTRATION
        //
        T1_REGISTRATION(
            PREPROC_T1.out.t1_final,
            PREPROC_DWI.out.b0,
            RECONST_DTIMETRICS.out.fa,
            Channel.empty(),
            Channel.empty(),
            Channel.empty()
        )
        ch_versions = ch_versions.mix(T1_REGISTRATION.out.versions.first())

        /* SEGMENTATION */

        //
        // MODULE: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_BRAINMASK)
        //
        TRANSFORM_BRAINMASK(
            PREPROC_T1.out.mask_final
                .join(PREPROC_DWI.out.b0)
                .join(T1_REGISTRATION.out.transfo_image)
        )
        ch_versions = ch_versions.mix(TRANSFORM_BRAINMASK.out.versions.first())

        //
        // MODULE: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_WMPARC)
        //
        TRANSFORM_WMPARC(
            ch_wmparc
                .join(PREPROC_DWI.out.b0)
                .join(T1_REGISTRATION.out.transfo_image)
        )
        ch_versions = ch_versions.mix(TRANSFORM_WMPARC.out.versions.first())

        //
        // MODULE: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_APARC_ASEG)
        //
        TRANSFORM_APARC_ASEG(
            ch_aparc_aseg
                .join(PREPROC_DWI.out.b0)
                .join(T1_REGISTRATION.out.transfo_image)
        )
        ch_versions = ch_versions.mix(TRANSFORM_APARC_ASEG.out.versions.first())

        //
        // Module: Run REGISTRATION_ANTSAPPLYTRANSFORMS (TRANSFORM_LESION_MASK)
        TRANSFORM_LESION_MASK(
            ch_lesion_mask
                .join(PREPROC_DWI.out.b0)
                .join(T1_REGISTRATION.out.transfo_image)
        )
        ch_versions = ch_versions.mix(TRANSFORM_LESION_MASK.out.versions.first())

        //
        // SUBWORKFLOW: Run ANATOMICAL_SEGMENTATION
        //
        ANATOMICAL_SEGMENTATION(
            T1_REGISTRATION.out.image_warped,
            TRANSFORM_WMPARC.out.warped_image
                .join(TRANSFORM_APARC_ASEG.out.warped_image),
            TRANSFORM_LESION_MASK.out.warped_image,
            Channel.empty()
        )
        ch_versions = ch_versions.mix(ANATOMICAL_SEGMENTATION.out.versions.first())

        /* RECONSTRUCTION - PART II - needs anatomy */

        //
        // MODULE: Run RECONST/FRF
        //
        ch_reconst_frf = PREPROC_DWI.out.dwi
            .join(PREPROC_DWI.out.bval)
            .join(PREPROC_DWI.out.bvec)
            .join(PREPROC_DWI.out.b0_mask)
            .join(ANATOMICAL_SEGMENTATION.out.wm_mask)
            .join(ANATOMICAL_SEGMENTATION.out.gm_mask)
            .join(ANATOMICAL_SEGMENTATION.out.csf_mask)

        RECONST_FRF( ch_reconst_frf )
        ch_versions = ch_versions.mix(RECONST_FRF.out.versions.first())

        /* Run fiber response averaging over subjects */
        ch_single_frf = RECONST_FRF.out.frf
            .map{ it + [[], []] }

        ch_fiber_response = RECONST_FRF.out.wm_frf
            .join(RECONST_FRF.out.gm_frf)
            .join(RECONST_FRF.out.csf_frf)
            .mix(ch_single_frf)

        if ( params.frf_average_from_data ) {
            ch_single_frf = group_frf("ssst", RECONST_FRF.out.frf)

            ch_wm_frf = group_frf("wm", RECONST_FRF.out.wm_frf)
            ch_gm_frf = group_frf("gm", RECONST_FRF.out.gm_frf)
            ch_csf_frf = group_frf("csf", RECONST_FRF.out.csf_frf)

            ch_meanfrf = ch_single_frf
                .mix(ch_wm_frf)
                .mix(ch_gm_frf)
                .mix(ch_csf_frf)

            RECONST_MEANFRF( ch_meanfrf )
            ch_versions = ch_versions.mix(RECONST_MEANFRF.out.versions.first())

            ch_meanfrf = RECONST_MEANFRF.out.meanfrf
                .map{ ["frf"] + it }
                .branch{
                    ssst: it[1] == "ssst"
                    wm: it[1] == "wm"
                    gm: it[1] == "gm"
                    csf: it[1] == "csf"
                }

            ch_fiber_response = ch_meanfrf.wm.map{ [it[0], it[2]] }
                .join(ch_meanfrf.gm.map{ [it[0], it[2]] })
                .join(ch_meanfrf.csf.map{ [it[0], it[2]] })
                .map{ it[1..-1] }
                .mix(ch_meanfrf.ssst.map{ [it[1], [], []] })
                .combine(RECONST_FRF.out.map{ it[0] })
        }

        //
        // MODULE: Run RECONST/FODF
        //
        ch_reconst_fodf = PREPROC_DWI.out.dwi
            .join(PREPROC_DWI.out.bval)
            .join(PREPROC_DWI.out.bvec)
            .join(PREPROC_DWI.out.b0_mask)
            .join(RECONST_DTIMETRICS.out.fa)
            .join(RECONST_DTIMETRICS.out.md)
            .join(ch_fiber_response)
        RECONST_FODF( ch_reconst_fodf )
        ch_versions = ch_versions.mix(RECONST_FODF.out.versions.first())

        //
        // MODULE: Run TRACKING/PFTTRACKING
        //
        ch_pft_tracking = Channel.empty()
        if ( params.run_pft ) {
            ch_input_pft_tracking = ANATOMICAL_SEGMENTATION.out.wm_mask
                .join(ANATOMICAL_SEGMENTATION.out.gm_mask)
                .join(ANATOMICAL_SEGMENTATION.out.csf_mask)
                .join(RECONST_FODF.out.fodf)
                .join(RECONST_DTIMETRICS.out.fa)
            TRACKING_PFTTRACKING( ch_input_pft_tracking )
            ch_versions = ch_versions.mix(TRACKING_PFTTRACKING.out.versions.first())

            ch_pft_tracking = TRACKING_PFTTRACKING.out.trk
                .join(TRACKING_PFTTRACKING.out.config)
                .join(TRACKING_PFTTRACKING.out.includes)
                .join(TRACKING_PFTTRACKING.out.excludes)
                .join(TRACKING_PFTTRACKING.out.seeding)
        }

        //
        // MODULE: Run TRACKING/LOCALTRACKING
        //
        ch_local_tracking = Channel.empty()
        if ( params.run_local_tracking ) {
            ch_input_local_tracking = ANATOMICAL_SEGMENTATION.out.wm_mask
                .join(RECONST_FODF.out.fodf)
                .join(RECONST_DTIMETRICS.out.fa)
            TRACKING_LOCALTRACKING( ch_input_local_tracking )
            ch_versions = ch_versions.mix(TRACKING_LOCALTRACKING.out.versions.first())

            ch_local_tracking = TRACKING_LOCALTRACKING.out.trk
                .join(TRACKING_LOCALTRACKING.out.config)
                .join(TRACKING_LOCALTRACKING.out.seedmask)
                .join(TRACKING_LOCALTRACKING.out.trackmask)
        }

    emit:

        // IN DIFFUSION SPACE
        dwi                     = PREPROC_DWI.out.dwi
                                    .join(PREPROC_DWI.out.bval)
                                    .join(PREPROC_DWI.out.bvec)
        t1                      = T1_REGISTRATION.out.image_warped
        brain_mask              = TRANSFORM_BRAINMASK.out.warped_image
        wm_mask                 = ANATOMICAL_SEGMENTATION.out.wm_mask
        gm_mask                 = ANATOMICAL_SEGMENTATION.out.gm_mask
        csf_mask                = ANATOMICAL_SEGMENTATION.out.csf_mask
        wm_map                  = ANATOMICAL_SEGMENTATION.out.wm_map
        gm_map                  = ANATOMICAL_SEGMENTATION.out.gm_map
        csf_map                 = ANATOMICAL_SEGMENTATION.out.csf_map
        aparc_aseg              = TRANSFORM_APARC_ASEG.out.warped_image
        wmparc                  = TRANSFORM_WMPARC.out.warped_image

        // REGISTRATION
        anatomical_to_diffusion = T1_REGISTRATION.out.transfo_image
        diffusion_to_anatomical = T1_REGISTRATION.out.transfo_trk

        // IN ANATOMICAL SPACE
        t1_native               = PREPROC_T1.out.t1_final

        // DTI
        dti_tensor              = RECONST_DTIMETRICS.out.tensor
        dti_md                  = RECONST_DTIMETRICS.out.md
        dti_rd                  = RECONST_DTIMETRICS.out.rd
        dti_ad                  = RECONST_DTIMETRICS.out.ad
        dti_fa                  = RECONST_DTIMETRICS.out.fa
        dti_rgb                 = RECONST_DTIMETRICS.out.rgb
        dti_peaks               = RECONST_DTIMETRICS.out.evecs_v1
        dti_evecs               = RECONST_DTIMETRICS.out.evecs
        dti_evals               = RECONST_DTIMETRICS.out.evals
        dti_residual            = RECONST_DTIMETRICS.out.residual
        dti_ga                  = RECONST_DTIMETRICS.out.ga
        dti_mode                = RECONST_DTIMETRICS.out.mode
        dti_norm                = RECONST_DTIMETRICS.out.norm

        // FODF
        fiber_response          = ch_fiber_response
        fodf                    = RECONST_FODF.out.fodf
        wm_fodf                 = RECONST_FODF.out.wm_fodf
        gm_fodf                 = RECONST_FODF.out.gm_fodf
        csf_fodf                = RECONST_FODF.out.csf_fodf
        fodf_rgb                = RECONST_FODF.out.vf_rgb
        fodf_peaks              = RECONST_FODF.out.peaks
        afd_max                 = RECONST_FODF.out.afd_max
        afd_total               = RECONST_FODF.out.afd_total
        afd_sum                 = RECONST_FODF.out.afd_sum
        nufo                    = RECONST_FODF.out.nufo
        volume_fraction         = RECONST_FODF.out.vf

        // TRACKING
        pft_tractogram          = ch_pft_tracking.map{ [it[0], it[1]] }
        pft_config              = ch_pft_tracking.map{ [it[0], it[2]] }
        pft_map_include         = ch_pft_tracking.map{ [it[0], it[3]] }
        pft_map_exclude         = ch_pft_tracking.map{ [it[0], it[4]] }
        pft_seeding_mask        = ch_pft_tracking.map{ [it[0], it[5]] }
        local_tractogram        = ch_local_tracking.map{ [it[0], it[1]] }
        local_config            = ch_local_tracking.map{ [it[0], it[2]] }
        local_seeding_mask      = ch_local_tracking.map{ [it[0], it[3]] }
        local_tracking_mask     = ch_local_tracking.map{ [it[0], it[4]] }

        // QC
        nonphysical_voxels      = RECONST_DTIMETRICS.out.nonphysical
        pulsation_in_dwi        = RECONST_DTIMETRICS.out.pulsation_std_dwi
        pulsation_in_b0         = RECONST_DTIMETRICS.out.pulsation_std_b0
        dti_residual_stats      = RECONST_DTIMETRICS.out.residual_residuals_stats

        versions                = ch_versions                 // channel: [ path(versions.yml) ]
}
