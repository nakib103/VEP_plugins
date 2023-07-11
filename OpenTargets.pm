=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2023] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 CONTACT

 Ensembl <http://www.ensembl.org/info/about/contact/index.html>
    
=cut

=head1 NAME

 OpenTargets

=head1 SYNOPSIS

 mv OpenTargets.pm ~/.vep/Plugins

 # print Open Targets Genetics scores (default)
 ./vep -i variations.vcf --plugin OpenTargets,file=path/to/data.tsv.bz
 
 # print all information from Open Targets Genetics
 ./vep -i variations.vcf --plugin OpenTargets,file=path/to/data.tsv.bz,cols=all

=head1 DESCRIPTION

 A VEP plugin that integrates data from Open Targets Genetics
 (https://genetics.opentargets.org), a tool that highlights variant-centric
 statistical evidence to allow both prioritisation of candidate causal variants
 at trait-associated loci and identification of potential drug targets.

 Data from Open Targets Genetics includes locus-to-gene (L2G) scores to predict
 causal genes at GWAS loci.

 Options are passed to the plugin as key=value pairs:
   file : (mandatory) Tabix-indexed file from Open Targets Genetics
   cols : (optional) Colon-separated list of columns to print (default: "l2g")

 Please cite the Open Targets Genetics publication alongside the VEP if you use
 this resource: https://doi.org/10.1093/nar/gkaa84

 The tabix utility must be installed in your path to use this plugin.

=cut

package OpenTargets;

use strict;
use warnings;

use File::Basename;
use Bio::SeqUtils;
use Bio::EnsEMBL::Variation::Utils::Sequence qw(get_matched_variant_alleles);

use Bio::EnsEMBL::Variation::Utils::BaseVepTabixPlugin;
use base qw(Bio::EnsEMBL::Variation::Utils::BaseVepTabixPlugin);

sub _prefix_cols {
  my $cols = shift;
  my $prefix = 'OpenTargets_';
  my @prefixed_cols = map { $_ =~ /^$prefix/ ? $_ : $prefix . $_ } @$cols;
  return \@prefixed_cols;
}

sub _get_colnames {
  my $self = shift;

  # Open file header
  open IN, "tabix -H " . $self->{_files}[0] . " |"
    or die "ERROR: cannot open tabix file for " . $self->{_files}[0];

  # Get last line from header
  my $last;
  $last = $_ while <IN>;
  $last =~ s/(^#|\n$)//g;
  close IN;

  # Parse column names from header
  my @cols = split /\t/, $last;
  @cols = splice @cols, 4; # first columns only identify the variant

  # Prefix all column names
  return _prefix_cols(\@cols);
}

sub _parse_colnames {
  my $self = shift;
  my $cols = shift;

  # Parse file columns
  $self->{colnames} = $self->_get_colnames();
  
  if ($cols eq "all") {
    $self->{cols} = $self->{colnames};
  } else {
    my @cols = split(/:/, $cols);

    # Prefix all column names
    $self->{cols} = _prefix_cols(\@cols);

    # Check validity of all columns
    my @invalid_cols = grep { !($_ ~~ $self->{colnames}) } $self->{cols};
    die "\n  ERROR: The following columns were not found in file header: ",
      join(", ", @invalid_cols), "\n" if @invalid_cols;
  }
}

sub new {
  my $class = shift;  
  my $self = $class->SUPER::new(@_);

  $self->expand_left(0);
  $self->expand_right(0);
  $self->get_user_params();

  my $param_hash = $self->params_to_hash();
  my $tr_match = $param_hash->{transcript_match};
  $self->{transcript_match} = defined $tr_match ? $tr_match : 1;

  my $aa_changes = $param_hash->{single_aminoacid_changes};
  $self->{single_aa_changes} = defined $aa_changes ? $aa_changes : 1;

  # Check file
  my $file = $param_hash->{file};
  die "\n  ERROR: No file specified\nTry using 'file=path/to/data.tsv.bz'\n"
     unless defined($file);
  $self->add_file($file);

  # Parse column names
  my $cols = $param_hash->{cols} || "l2g";
  $self->_parse_colnames($cols);

  return $self;
}

sub feature_types {
  return ['Feature', 'Intergenic'];
}

sub get_header_info {
  my $self = shift;
  my %header;
  my @keys = @{ $self->{colnames} };

  my $description = "column from " . basename $self->{_files}[0];
  my @vals = map { $description } @keys;
  @header{ @keys } = @vals;

  # Custom headers
  $header{"OpenTargets_l2g"}  = "Locus-to-gene (L2G) scores to predict causal genes at GWAS loci; " . $description;

  # Filter by user-selected columns
  %header = map { $_ => $header{$_} } @{ $self->{cols} };

  return \%header;
}

sub run {
  my ($self, $tva) = @_;
  
  my $vf = $tva->variation_feature;
  my $allele = $tva->base_variation_feature->alt_alleles;
  my @data = @{$self->get_data($vf->{chr}, $vf->{start} - 2, $vf->{end})};

  foreach (@data) {
    # Check if genes match
    next unless 
      $tva->transcript->{_gene_stable_id} eq $_->{result}->{OpenTargets_geneId};

    my $matches = get_matched_variant_alleles(
      {
        ref    => $vf->ref_allele_string,
        alts   => $allele,
        pos    => $vf->{start},
        strand => $vf->strand
      },
      {
       ref  => $_->{ref},
       alts => [$_->{alt}],
       pos  => $_->{start},
      }
    );
    return $_->{result} if @$matches;
  }
  return {};
}

sub parse_data {
  my ($self, $line) = @_;
  my ($chrom, $pos, $ref, $alt, @vals) = split /\t/, $line;
  my $start = $pos;
  my $end   = $pos;

  # VCF-like adjustment of mismatched substitutions for comparison with VEP
  if(length($alt) != length($ref)) {
    my $first_ref = substr($ref, 0, 1);
    my $first_alt = substr($alt, 0, 1);
    if ($first_ref eq $first_alt) {
      $start++;
      $ref = substr($ref, 1);
      $alt = substr($alt, 1);
      $ref ||= '-';
      $alt ||= '-';
    }
  }
  
  my %res;
  @res{ @{ $self->{colnames} } } = @vals;

  return {
    ref => $ref,
    alt => $alt,
    start => $start,
    result => \%res
  };
}

sub get_start {
  return $_[1]->{start};
}

sub get_end {
  return $_[1]->{end};
}

1;
