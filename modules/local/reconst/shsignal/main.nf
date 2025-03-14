
process RECONST_SHSIGNAL {
    tag "$meta.id"
    label 'process_single'

    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://scil.usherbrooke.ca/containers/scilus_2.0.2.sif':
        'scilus/scilus:2.0.2' }"

    input:
        tuple val(meta), path(dwi), path(bval), path(bvec),path(mask)

    output:
        tuple val(meta), path("*__dwi_sh.nii.gz")   , emit: sh_signal
        path "versions.yml"                         , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def dwi_shell_tolerance = task.ext.dwi_shell_tolerance ? "--tolerance $task.ext.dwi_shell_tolerance" : ""
    def max_shell_bvalue = task.ext.max_shell_bvalue ?: 1500
    def b0_thr_extract_b0 = task.ext.b0_thr_extract_b0 ?: 10
    def b0_threshold = task.ext.b0_thr_extract_b0 ? "--b0_threshold $task.ext.b0_thr_extract_b0" : ""
    def shells_to_fit = task.ext.shells_to_fit ?: "\$(cut -d ' ' --output-delimiter=\$'\\n' -f 1- $bval | awk -F' ' '{v=int(\$1)}{if(v<=$max_shell_bvalue|| v<=$b0_thr_extract_b0)print v}' | uniq)"
    def sh_order = task.ext.sh_order ? "--sh_order $task.ext.sh_order" : ""
    def sh_basis = task.ext.sh_basis ? "--sh_basis $task.ext.sh_basis" : ""
    def smoothing = task.ext.smoothing ? "--smooth $task.ext.smoothing" : ""
    def attenuation_only = task.ext.fit_attenuation_only ? "--use_attenuation" : ""

    if ( mask ) args += " --mask $mask"
    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1
    export OMP_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1

    scil_dwi_extract_shell.py $dwi $bval $bvec $shells_to_fit \
        dwi_sh_shells.nii.gz bval_sh_shells bvec_sh_shells \
        $dwi_shell_tolerance -f

    scil_dwi_to_sh.py dwi_sh_shells.nii.gz bval_sh_shells bvec_sh_shells \
        ${prefix}__dwi_sh.nii.gz \
        $sh_order $sh_basis $smoothing \
        $attenuation_only $b0_threshold $args

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: \$(pip list --disable-pip-version-check --no-python-version-warning | grep scilpy | tr -s ' ' | cut -d' ' -f2)
    END_VERSIONS
    """

    stub:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"

    """
    scil_dwi_extract_shell.py -h
    scil_dwi_to_sh.py -h

    touch ${prefix}__dwi_sh.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        scilpy: \$(pip list --disable-pip-version-check --no-python-version-warning | grep scilpy | tr -s ' ' | cut -d' ' -f2)
    END_VERSIONS
    """
}
