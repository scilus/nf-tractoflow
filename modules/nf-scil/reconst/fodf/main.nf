
process RECONST_FODF {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://scil.usherbrooke.ca/containers/scilus_1.6.0.sif':
        'scilus/scilus:1.6.0' }"

    input:
        tuple val(meta), path(dwi), path(bval), path(bvec), path(mask), path(fa), path(md), path(frf)

    output:
        tuple val(meta), path("*fodf.nii.gz")           , emit: fodf
        tuple val(meta), path("*peaks.nii.gz")          , emit: peaks, optional: true
        tuple val(meta), path("*peak_indices.nii.gz")   , emit: peak_indices, optional: true
        tuple val(meta), path("*afd_max.nii.gz")        , emit: afd_max, optional: true
        tuple val(meta), path("*afd_total.nii.gz")      , emit: afd_total, optional: true
        tuple val(meta), path("*afd_sum.nii.gz")        , emit: afd_sum, optional: true
        tuple val(meta), path("*nufo.nii.gz")           , emit: nufo, optional: true
        path "versions.yml"                             , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"

    def dwi_shell_tolerance = task.ext.dwi_shell_tolerance ? "--tolerance " + task.ext.dwi_shell_tolerance : ""
    def fodf_shells = task.ext.fodf_shells ?: "\$(cut -d ' ' --output-delimiter=\$'\\n' -f 1- $bval | awk -F' ' '{v=int(\$1)}{if(v>=$task.ext.min_fodf_shell_value|| v<=$task.ext.b0_thr_extract_b0)print v}' | uniq)"
    def sh_order = task.ext.sh_order ? "--sh_order " + task.ext.sh_order : ""
    def sh_basis = task.ext.sh_basis ? "--sh_basis " + task.ext.sh_basis : ""
    def fa_threshold = task.ext.fa_threshold ? "--fa_t " + task.ext.fa_threshold : ""
    def md_threshold = task.ext.md_threshold ? "--md_t " + task.ext.md_threshold : ""
    def relative_threshold = task.ext.relative_threshold ? "--rt " + task.ext.relative_threshold : ""
    def fodf_metrics_a_factor = task.ext.fodf_metrics_a_factor ? task.ext.fodf_metrics_a_factor : 2.0
    def processes = task.ext.processes ? "--processes " + task.ext.processes : ""
    def set_mask = mask ? "--mask $mask" : ""
    def absolute_peaks = task.ext.absolute_peaks ? "--abs_peaks_and_values" : ""

    if ( task.ext.peaks ) peaks = "--peaks ${prefix}__peaks.nii.gz" else peaks = ""
    if ( task.ext.peak_indices ) peak_indices = "--peak_indices ${prefix}__peak_indices.nii.gz" else peak_indices = ""
    if ( task.ext.afd_max ) afd_max = "--afd_max ${prefix}__afd_max.nii.gz" else afd_max = ""
    if ( task.ext.afd_total ) afd_total = "--afd_total ${prefix}__afd_total.nii.gz" else afd_total = ""
    if ( task.ext.afd_sum ) afd_sum = "--afd_sum ${prefix}__afd_sum.nii.gz" else afd_sum = ""
    if ( task.ext.nufo ) nufo = "--nufo ${prefix}__nufo.nii.gz" else nufo = ""

    def run_fodf_metrics = [
        task.ext.peaks, task.ext.peak_indices, task.ext.afd_max,
        task.ext.afd_sum, task.ext.afd_total, task.ext.nufo
    ].any()

    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
    export OMP_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1

    scil_extract_dwi_shell.py $dwi $bval $bvec $fodf_shells \
        dwi_fodf_shells.nii.gz bval_fodf_shells bvec_fodf_shells \
        $dwi_shell_tolerance -f

    scil_compute_ssst_fodf.py dwi_fodf_shells.nii.gz bval_fodf_shells bvec_fodf_shells $frf ${prefix}__fodf.nii.gz \
        $sh_order $sh_basis --force_b0_threshold \
        $set_mask $processes

    if $run_fodf_metrics
    then

        scil_compute_fodf_max_in_ventricles.py ${prefix}__fodf.nii.gz $fa $md \
        --max_value_output ventricles_fodf_max_value.txt $sh_basis \
        $fa_threshold $md_threshold --mask_output ventricles_mask.nii.gz -f

        echo "Maximal peak value in ventricle in file : \$(cat ventricles_fodf_max_value.txt)"

        a_factor=$fodf_metrics_a_factor
        v_max=\$(sed -E 's/([+-]?[0-9.]+)[eE]\\+?(-?)([0-9]+)/(\\1*10^\\2\\3)/g' <<<"\$(cat ventricles_fodf_max_value.txt)")

        echo "Maximal peak value in ventricles : \${v_max}"

        a_threshold=\$(echo "scale=10; \${a_factor} * \${v_max}" | bc)
        if (( \$(echo "\${a_threshold} <= 0" | bc -l) )); then
            a_threshold=1E-10
        fi

        echo "Computing fodf metrics with absolute threshold : \${a_threshold}"

        scil_compute_fodf_metrics.py ${prefix}__fodf.nii.gz \
            $set_mask $sh_basis $absolute_peaks \
            $peaks $peak_indices \
            $afd_max $afd_total \
            $afd_sum $nufo \
            $relative_threshold --not_all --at \${a_threshold}
    fi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: 1.6.0
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    scil_extract_dwi_shell.py -h
    scil_compute_ssst_fodf.py -h
    scil_compute_fodf_max_in_ventricles.py -h
    scil_compute_fodf_metrics.py -h

    touch ${prefix}__fodf.nii.gz
    touch ${prefix}__peaks.nii.gz
    touch ${prefix}__peak_indices.nii.gz
    touch ${prefix}__afd_max.nii.gz
    touch ${prefix}__afd_total.nii.gz
    touch ${prefix}__afd_sum.nii.gz
    touch ${prefix}__nufo.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: 1.6.0
    END_VERSIONS
    """
}
