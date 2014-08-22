package CPANio::Board::OnceA;

use 5.010;
use strict;
use warnings;

use CPANio;
use CPANio::Board;
our @ISA = qw( CPANio::Board );

# CONSTANTS
my @CATEGORIES = qw( month week day );
my %LIKE = (
    month => 'M%',
    week  => 'W%',
    day   => 'D%',
);

# PRIVATE FUNCTIONS
sub _get_bins_for {
    my ($category) = @_;
    state %bins;

    return $bins{$category} ||= [
        $CPANio::schema->resultset('ReleaseBins')->search(
            {   author => '',
                bin    => { like => $LIKE{$category} },
            },
            { order_by => { -desc => 'bin' } }
        )->get_column('bin')->all
    ];
}

sub _find_authors_chains {
    my $schema  = $CPANio::schema;
    my $bins_rs = $schema->resultset('ReleaseBins');

    my %chains;
    for my $category (@CATEGORIES) {

        # pick the bins for the current category
        my @bins = @{ _get_bins_for($category) };

        # get the list of bins for all the authors
        my %bins;
        push @{ $bins{ $_->author } }, $_->bin
            for $bins_rs->search(
            { author => { '!=' => '' }, bin => { like => $LIKE{$category} } },
            { order_by => { -desc => 'bin' } }
            );

        # process each author's bins
        for my $author ( keys %bins ) {
            my $Bins = delete $bins{$author};
            my @chains;
            my $i = 0;

            # split the bins into chains
            while (@$Bins) {
                $i++ while $Bins->[0] ne $bins[$i];
                my $j = 0;
                while ( $Bins->[$j] eq $bins[$i] ) {
                    $i++;
                    $j++;
                    last if $j >= @$Bins;
                }
                my $chain = [ splice @$Bins, 0, $j ];
                push @chains, $chain if @$chain >= 2;
            }
            $bins{$author} = \@chains if @chains;
        }
        $chains{$category} = \%bins;
    }

    return \%chains;
}

sub _commit_entries {
    my ( $category, $contest, $entries ) = @_;

    # sort chains
    @$entries = sort { $b->{count} <=> $a->{count} } @$entries;

    # compute rank
    my $Rank = my $rank = my $prev = 0;
    for my $entry (@$entries) {
        $Rank++;
        $rank          = $Rank if $entry->{count} != $prev;
        $prev          = $entry->{count};
        $entry->{rank} = $rank;
    }

    # update database
    my $rs = $CPANio::schema->resultset("OnceA\u$category");
    $rs->search( { contest => $contest } )->delete();
    $rs->populate($entries);
}

sub _compute_boards_current {
    my ($chains) = @_;

    for my $category (@CATEGORIES) {

        # pick the bins for the current category
        my $bins = _get_bins_for($category);

        # only keep the active chains
        my @entries;
        for my $author ( keys %{ $chains->{$category} } ) {
            my $chain = $chains->{$category}{$author}[0]; # current chain only
            if ( $chain->[0] eq $bins->[0] || $chain->[0] eq $bins->[1] ) {
                push @entries, {
                    contest => 'current',
                    author  => $author,
                    count   => scalar @$chain,
                    safe    => 0 + ( $chain->[0] eq $bins->[0] ),
                    active  => 0,
                    };
            }
        }

        _commit_entries( $category, 'current', \@entries );
    }
}

sub _compute_boards_alltime {
    my ($chains) = @_;

    for my $category (@CATEGORIES) {

        # pick the bins for the current category
        my $bins = _get_bins_for($category);

        my @entries = map {
            my $author = $_;
            my $chains = $chains->{$category}{$author};
            my $chain  = shift @$chains;                  # possibly active
            {   contest => 'all-time',
                author  => $author,
                count   => scalar @$chain,
                safe    => 0 + ( $chain->[0] eq $bins->[0] ),
                active  => 0 + ( $chain->[0] eq $bins->[0] ),
            },
                map +{
                contest => 'all-time',
                author  => $author,
                count   => scalar @$_,
                safe    => 0,
                active  => 0,
                }, @$chains;
        } keys %{ $chains->{$category} };

        _commit_entries( $category, 'all-time', \@entries );
    }
}

# CLASS METHODS
sub board_name { 'once-a' }

sub update {
    my $since = __PACKAGE__->latest_update;

    # we depend on the bins
    require CPANio::Board::Bins;
    return if $since > CPANio::Board::Bins->latest_update;

    # pick up all the chains
    my $chains = _find_authors_chains();
    _compute_boards_current($chains);
    _compute_boards_alltime($chains);

    __PACKAGE__->update_done();
}

1;
