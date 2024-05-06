
def safecast_filetype( f, awaited_ext ) {
    if ( f.scheme in ["http", "https", "ftp", "s3"] ) {
        def name = "$f.parent/${f.simpleName}.${awaited_ext}"
        f.copyTo(name)
        return name
    }
    def ext = f.name.replace(f.simpleName, "")
    if ( ext == ".$awaited_ext" ) {
        return "$f"
    }

    error "File $f does not have the awaited extension $awaited_ext"
}


process IO_SAFECASTINPUTS {
    label 'process_single'

    input:
        tuple val(meta), path(dwi), path(bval), path(bvec), path(sbref), path(rev_dwi), path(rev_bval), path(rev_bvec), path(rev_sbref), path(t1), path(wmparc), path(aparc_aseg)
    output:
        tuple val(meta), path("$out_dwi"), path("$out_bval"), path("$out_bvec"), path("$out_sbref"), path("$out_rev_dwi"), path("$out_rev_bval"), path("$out_rev_bvec"), path("$out_rev_sbref"), path("$out_t1"), path("$out_wmparc"), path("$out_aparc_aseg"), emit: safe_inputs
    script:
        out_dwi = dwi ? safecast_filetype(dwi, 'nii.gz') : "$dwi"
        out_bval = bval ? safecast_filetype(bval, 'bval') : "$bval"
        out_bvec = bvec ? safecast_filetype(bvec, 'bvec') : "$bvec"
        out_sbref = sbref ? safecast_filetype(sbref, 'nii.gz') : "$sbref"
        out_rev_dwi = rev_dwi ? safecast_filetype(rev_dwi, 'nii.gz') : "$rev_dwi"
        out_rev_bval = rev_bval ? safecast_filetype(rev_bval, 'bval') : "$rev_bval"
        out_rev_bvec = rev_bvec ? safecast_filetype(rev_bvec, 'bvec') : "$rev_bvec"
        out_rev_sbref = rev_sbref ? safecast_filetype(rev_sbref, 'nii.gz') : "$rev_sbref"
        out_t1 = t1 ? safecast_filetype(t1, 'nii.gz') : "$t1"
        out_wmparc = wmparc ? safecast_filetype(wmparc, 'nii.gz') : "$wmparc"
        out_aparc_aseg = aparc_aseg ? safecast_filetype(aparc_aseg, 'nii.gz') : "$aparc_aseg"
    """
    """
}
