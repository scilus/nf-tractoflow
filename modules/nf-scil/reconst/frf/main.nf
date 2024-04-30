

process RECONST_FRF {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://scil.usherbrooke.ca/containers/scilus_1.6.0.sif':
        'scilus/scilus:1.6.0' }"

    input:
        tuple val(meta), path(dwi), path(bval), path(bvec), path(mask)

    output:
        tuple val(meta), path("*__frf.txt")             , emit: frf
        path "versions.yml"                             , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def fa = task.ext.fa ? "--fa " + task.ext.fa : ""
    def fa_min = task.ext.fa_min ? "--min_fa " + task.ext.fa_min : ""
    def nvox_min = task.ext.nvox_min ? "--min_nvox " + task.ext.nvox_min : ""
    def roi_radius = task.ext.roi_radius ? "--roi_radii " + task.ext.roi_radius : ""
    def fix_frf = task.ext.manual_frf ? task.ext.manual_frf : ""
    def set_mask = mask ? "--mask $mask" : ""

    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
    export OMP_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1

    scil_compute_ssst_frf.py $dwi $bval $bvec ${prefix}__frf.txt \
        $set_mask $fa $fa_min $nvox_min $roi_radius --force_b0_threshold

    if ( "$task.ext.set_frf" = true ); then
        scil_set_response_function.py ${prefix}__frf.txt "${fix_frf}" \
            ${prefix}__frf.txt -f
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: 1.6.0
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    scil_compute_ssst_frf.py -h
    scil_set_response_function.py -h

    touch ${prefix}__frf.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: 1.6.0
    END_VERSIONS
    """
}
