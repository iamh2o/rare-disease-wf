nextflow.enable.dsl=2

params.help = false
if(params.help) {

    log.info("""
------------------------------------------
octopus workflow

Required Arguments
------------------

    --ped       pedigree file with the 6 required columns and a 7th column
                indicating the path to a bam or cram file for each sample.

    --fasta           Path to reference fasta
""")

}

params.ped = false
if(!params.ped) { exit 1, "--ped is required" }
params.fasta = false
if(!params.fasta) { exit 1, "--fasta reference is required" }
params.chunk_size = 250000000

process octopus_trio {
    input: each(region)
           tuple(val(sample), file(kid_bam), file(dad_bam), file(mom_bam))
           path(ref)
           path(fai)
    output: tuple(val("${sample.id}"), val("${region}"), path("${output_path}"))
    script:
       output_path="${sample.id}.${region.replaceAll(':','_')}.trio.vcf"
       """
echo octopus -R $ref -I ${kid_bam} ${dad_bam} ${mom_bam} -M  ${sample.mom.id} -F ${sample.dad.id} \
    -p Y=2 chrY=2 -w \$TMPDIR --threads ${task.cpus} --one-based-indexing -T ${region} \
    --bamout "${sample.id}.realigned.bams/" \
    -o ${output_path}
touch $output_path
       """
}

process octopus_fam_or_single {
    input: each(region)
           tuple(val(family_id), path(bams))
           path(ref)
           path(fai)
    output: tuple(val("${family_id}"), val("${region}"), path("${output_path}"))
    script:
       output_path="${family_id}.${region}.notrio.vcf"
       bamout="${family_id}.realigned.bams.fam/"
       if (bams.size() == 1 ) {
         bamout += "octopus.${family_id}.bam"
       }
       """
echo octopus -R $ref -I $bams \
    -p Y=2 chrY=2 -w \$TMPDIR --threads ${task.cpus} --one-based-indexing -T ${region} \
    --bamout ${bamout} \
    -o ${output_path}
touch $output_path
       """
}

process octopus_population {
    input: tuple(val(region), path(vcfs), path(crams))
           path(ref)
           path(fai)
    output: tuple(val("${region}"), path("${output_path}"))
    // TODO: use --bamout bams from previous? instead of original crams?
    script:
       output_path="${region}.population.vcf"
       """
echo octopus -R $ref -I $crams \
    -p Y=2 chrY=2 -w \$TMPDIR --threads ${task.cpus} --one-based-indexing \
    --disable-denovo-variant-discovery \
    -c ${vcfs} \
    -o ${output_path} > ${output_path}
       """
}




include { split_by_size } from "./split"

@groovy.transform.ToString(includeNames=true, ignoreNulls=true, excludes=["dad", "mom"])
public class Sample {
    String id
    String family_id
    String maternal_id
    String paternal_id
    java.nio.file.Path path
    Sample mom
    Sample dad
}

workflow {

    def trios = []
    def in_trio = [:]
    def sample_by_id = [:]
    def samples = []
    file(params.ped, checkIfExists:true).eachLine { line ->
        if(line[0] == '#' ) { return }
        def toks = line.split("\t")
        if(toks.size() != 7 ){
            println("ERROR: expecting 7 columns in pedigree file; found ${toks.size()} in line\n${line}")
        }
        s = new Sample(id: toks[1], family_id:toks[0], paternal_id: toks[2], maternal_id: toks[3], 
                       path: file(toks[6], checkIfExists: true))
        sample_by_id[s.id] = s
        samples.add(s)
    }
    // get trios
    samples.each { s ->
      s.mom = sample_by_id[s.maternal_id]
      s.dad = sample_by_id[s.paternal_id]
      if(s.dad && s.mom) {
         trios.add(s)
         in_trio[s.id] = true
         in_trio[s.maternal_id] = true
         in_trio[s.paternal_id] = true
      }
    }
    // now collect other samples that are not in a trio and group them by
    // family for calling
    def by_fam = [:]
    samples.each { s ->
        if(in_trio[s.id]) { return }
        if(!by_fam.containsKey(s.family_id)) {
            by_fam[(s.family_id)] = []
        }
        by_fam[(s.family_id)].add(s)
    }

    regions = split_by_size(params.fasta + ".fai", params.chunk_size).splitText() | map { s -> s.replaceAll("\\s", "") }

    trs = channel.fromList(trios) | map { it -> [it, it.path, it.dad.path, it.mom.path] } 
    trio_ch = octopus_trio(regions, trs, params.fasta, params.fasta + ".fai")

    // now add families to list 
    fams = []
    by_fam.each { li -> {
          fam = []
           
          li.value.each { it ->
            fam.add(it.path) 
          }
          fams.add(tuple(li.value[0].family_id, fam))
       }
    }


    by_region = octopus_fam_or_single(regions, channel.fromList(fams), params.fasta, params.fasta + ".fai").concat(trio_ch) 
              | groupTuple(by: 1, size: 20, remainder:true) \
              | map { it -> [it[1], it[2], it[0].collect(s -> sample_by_id[s].path)] } \

    by_region | view
    octopus_population(by_region, params.fasta, params.fasta + ".fai") | view
    

}
