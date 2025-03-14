process SEGMENTATION_FREESURFERSEG {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://scil.usherbrooke.ca/containers/scilus_2.0.2.sif':
        'scilus/scilus:2.0.2' }"

    input:
        tuple val(meta), path(aparc_aseg), path(wmparc), path(lesion)

    output:
        tuple val(meta), path("*__mask_wm.nii.gz")              , emit: wm_mask
        tuple val(meta), path("*__mask_gm.nii.gz")              , emit: gm_mask
        tuple val(meta), path("*__mask_csf.nii.gz")             , emit: csf_mask
        path "versions.yml"                                     , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
    export OMP_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1

    mkdir wmparc_desikan/
    mkdir wmparc_subcortical/
    mkdir aparc+aseg_subcortical/

    mrconvert -datatype int16 $aparc_aseg aparc+aseg_int16.nii.gz -force -nthreads 1
    mrconvert -datatype int16 $wmparc wmparc_int16.nii.gz -force -nthreads 1

    scil_labels_split_volume_from_lut.py wmparc_int16.nii.gz --scilpy_lut freesurfer_desikan_killiany --out_dir wmparc_desikan
    scil_labels_split_volume_from_lut.py wmparc_int16.nii.gz --scilpy_lut freesurfer_subcortical --out_dir wmparc_subcortical
    scil_labels_split_volume_from_lut.py aparc+aseg_int16.nii.gz --scilpy_lut freesurfer_subcortical --out_dir aparc+aseg_subcortical

    scil_volume_math.py union wmparc_desikan/*\
        wmparc_subcortical/right-cerebellum-cortex.nii.gz\
        wmparc_subcortical/left-cerebellum-cortex.nii.gz\
        mask_cortex_m.nii.gz -f

    scil_volume_math.py union wmparc_subcortical/corpus-callosum-*\
        aparc+aseg_subcortical/*white-matter*\
        wmparc_subcortical/brain-stem.nii.gz\
        aparc+aseg_subcortical/*ventraldc*\
        mask_wm_m.nii.gz -f

    scil_volume_math.py union wmparc_subcortical/*thalamus*\
        wmparc_subcortical/*putamen*\
        wmparc_subcortical/*pallidum*\
        wmparc_subcortical/*hippocampus*\
        wmparc_subcortical/*caudate*\
        wmparc_subcortical/*amygdala*\
        wmparc_subcortical/*accumbens*\
        wmparc_subcortical/*plexus*\
        mask_nuclei_m.nii.gz -f

    scil_volume_math.py union wmparc_subcortical/*-lateral-ventricle.nii.gz\
        wmparc_subcortical/*-inferior-lateral-ventricle.nii.gz\
        wmparc_subcortical/cerebrospinal-fluid.nii.gz\
        wmparc_subcortical/*th-ventricle.nii.gz\
        mask_csf_1_m.nii.gz -f

    scil_volume_math.py lower_threshold mask_wm_m.nii.gz 0.1\
        ${prefix}__mask_wm_bin.nii.gz -f
    scil_volume_math.py lower_threshold mask_cortex_m.nii.gz 0.1\
        ${prefix}__mask_gm.nii.gz -f
    scil_volume_math.py lower_threshold mask_nuclei_m.nii.gz 0.1\
        ${prefix}__mask_nuclei_bin.nii.gz -f
    scil_volume_math.py lower_threshold mask_csf_1_m.nii.gz 0.1\
        ${prefix}__mask_csf.nii.gz -f
    scil_volume_math.py addition ${prefix}__mask_wm_bin.nii.gz\
                                ${prefix}__mask_nuclei_bin.nii.gz\
                                ${prefix}__mask_wm.nii.gz --data_type int16

    scil_volume_math.py convert ${prefix}__mask_wm.nii.gz ${prefix}__mask_wm.nii.gz --data_type uint8 -f
    scil_volume_math.py convert ${prefix}__mask_gm.nii.gz ${prefix}__mask_gm.nii.gz --data_type uint8 -f
    scil_volume_math.py convert ${prefix}__mask_csf.nii.gz ${prefix}__mask_csf.nii.gz --data_type uint8 -f

    if [[ -f "$lesion" ]];
    then
        scil_volume_math.py union ${prefix}__mask_wm.nii.gz $lesion ${prefix}__mask_wm.nii.gz --data_type uint8 -f
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: \$(pip list | grep scilpy | tr -s ' ' | cut -d' ' -f2)
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/== mrconvert \\([0-9.]\\+\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    mrconvert -h
    scil_volume_math.py -h
    scil_labels_split_volume_from_lut.py -h

    touch ${prefix}__mask_wm.nii.gz
    touch ${prefix}__mask_gm.nii.gz
    touch ${prefix}__mask_csf.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: \$(pip list | grep scilpy | tr -s ' ' | cut -d' ' -f2)
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/== mrconvert \\([0-9.]\\+\\).*/\\1/p')
    END_VERSIONS
    """
}
