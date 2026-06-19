cd ~/projects/HomoPan_ancestor

# 1. Dejar solo las 5 especies que usaremos
cat > accessions.tsv << 'EOF'
homo_sapiens GCA_009914755.4
pan_paniscus GCF_029289425.2
pan_troglodytes GCF_028858775.2
gorilla_gorilla_gorilla GCF_029281585.2
pongo_abelii GCF_028885655.2
EOF

# 2. Verificar que las 5 FASTA existen
for ID in homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii; do
  ls -lh genomes/${ID}.fa || echo "MISSING: genomes/${ID}.fa"
done

# 3. Recrear los test FASTA solo con esas 5 especies
rm -rf test_genomes
mkdir -p test_genomes

for ID in homo_sapiens pan_paniscus pan_troglodytes gorilla_gorilla_gorilla pongo_abelii; do
  echo "Creating test FASTA for $ID"
  seqkit head -n 1 genomes/${ID}.fa \
    | seqkit subseq -r 1:1000000 \
    > test_genomes/${ID}.test1Mb.fa

  samtools faidx test_genomes/${ID}.test1Mb.fa
done

# 4. Seqfile de prueba SIN macaca
cat > primates.test.seqfile << EOF
(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;
homo_sapiens $PWD/test_genomes/homo_sapiens.test1Mb.fa
pan_paniscus $PWD/test_genomes/pan_paniscus.test1Mb.fa
pan_troglodytes $PWD/test_genomes/pan_troglodytes.test1Mb.fa
gorilla_gorilla_gorilla $PWD/test_genomes/gorilla_gorilla_gorilla.test1Mb.fa
pongo_abelii $PWD/test_genomes/pongo_abelii.test1Mb.fa
EOF

# 5. Seqfile completo SIN macaca
cat > primates.seqfile << EOF
(((homo_sapiens,(pan_paniscus,pan_troglodytes)Pan)Anc_HomoPan,gorilla_gorilla_gorilla)Homininae,pongo_abelii)Root;
homo_sapiens $PWD/genomes/homo_sapiens.fa
pan_paniscus $PWD/genomes/pan_paniscus.fa
pan_troglodytes $PWD/genomes/pan_troglodytes.fa
gorilla_gorilla_gorilla $PWD/genomes/gorilla_gorilla_gorilla.fa
pongo_abelii $PWD/genomes/pongo_abelii.fa
EOF

# 6. Verificar que el seqfile tiene 2 columnas después del árbol
cat -n primates.test.seqfile
awk 'NR>1{print NF, $1, $2}' primates.test.seqfile
