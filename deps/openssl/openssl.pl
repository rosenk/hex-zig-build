#!/usr/bin/env perl
# OpenSSL's own configuration and source generation, without make, for
# build.zig. OpenSSL's Configure decides everything; this only reads its
# configdata.pm and runs the generators its Makefile template would.
#
#   openssl.pl plan     SRC DIR TARGET [OPTION...]   print what to compile
#   openssl.pl generate SRC DIR TARGET [OPTION...]   write the generated files
#
# Both run Configure out of tree in DIR (plan only when DIR has no plan for the
# same arguments yet, then reprints it). The plan has one record per line:
#
#   define <lib> <macro>     a -D for every source of <lib> (libcrypto, libssl)
#   include <lib> <path>     an include directory, in order
#   source <lib> <path>      a C or assembler source
#
# where <path> is src/<relative path> (the source tree) or gen/<relative
# path> (DIR, where `generate` writes).
use strict;
use warnings;
no warnings "once";
use Cwd qw(abs_path getcwd);
use File::Path qw(make_path);
use File::Spec::Functions qw(abs2rel catfile rel2abs);
use File::Basename qw(dirname basename);

my ($command, $src, $dir, $target, @options) = @ARGV;
die "usage: $0 plan|generate SRC DIR TARGET [OPTION...]\n" unless $command && $src && $dir && $target;
$src = abs_path($src);
my $self = slurp($0);
make_path($dir);
$dir = abs_path($dir);
chdir $dir or die "cannot enter $dir: $!\n";

my $key = join("\0", $src, $target, @options, $self);
if ($command eq 'plan' && -f 'plan.txt' && -f 'plan.key' && slurp('plan.key') eq $key) {
    print slurp('plan.txt');
    exit 0;
}

configure();
our (%config, %target, %unified_info);
{
    local @INC = ($dir, @INC);
    require configdata;
    *config = \%configdata::config;
    *target = \%configdata::target;
    *unified_info = \%configdata::unified_info;
}

my @libs = ('libcrypto', 'libssl');
if ($command eq 'plan') {
    my $plan = plan();
    spit('plan.txt', $plan);
    spit('plan.key', $key);
    print $plan;
} elsif ($command eq 'generate') {
    generate();
} else {
    die "unknown command $command\n";
}

sub configure {
    my @argv = ($^X, catfile($src, 'Configure'), $target, @options);
    open(my $log, '>', 'configure.log') or die;
    my $pid = fork() // die "fork: $!\n";
    if ($pid == 0) {
        open(STDOUT, '>&', $log) or die;
        open(STDERR, '>&', $log) or die;
        exec(@argv) or die "exec: $!\n";
    }
    waitpid($pid, 0);
    die "Configure failed (see $dir/configure.log)\n" if $?;
}

# A path Configure wrote relative to DIR, as src/… or gen/….
sub classify {
    my ($path) = @_;
    my $abs = rel2abs($path, $dir);
    $abs = abs_path($abs) // $abs if -e $abs;
    return 'src/' . abs2rel($abs, $src) if index($abs, "$src/") == 0 || $abs eq $src;
    return 'gen/' . abs2rel($abs, $dir);
}

# A library and the internal static libraries it takes in, through their
# sources and dependencies (libcrypto: providers/libdefault.a and
# liblegacy.a, which depend on providers/libcommon.a). Each carries its own
# defines and include directories for its objects.
sub parts {
    my ($product, $seen) = @_;
    $seen //= {};
    return () if $seen->{$product}++;
    my @inner = grep { /\.a$/ } (@{$unified_info{sources}{$product} // []},
                                  @{$unified_info{depends}{$product} // []});
    return ($product, map { parts($_, $seen) } @inner);
}

# The object files of a library and the static libraries it takes in.
sub objects {
    my ($product) = @_;
    return grep { !/\.a$/ } map { @{$unified_info{sources}{$_} // []} } parts($product);
}

sub plan {
    my $out = '';
    my @cppflags = map { split ' ', ($_ // '') }
        ($target{cppflags}, $target{lib_cppflags}, $config{cppflags}, $config{lib_cppflags});
    for my $lib (@libs) {
        my @defines = (@{$config{defines}}, @{$config{lib_defines}},
                       @{$target{defines} // []}, @{$target{lib_defines} // []},
                       map { @{$unified_info{defines}{$_} // []} } parts($lib));
        push @defines, map { substr($_, 2) } grep { /^-D/ } @cppflags;
        my %seen;
        $out .= "define $lib $_\n" for grep { !$seen{$_}++ } @defines;
        my %inc;
        for my $inc (map { @{$unified_info{includes}{$_} // []} } parts($lib)) {
            my $c = classify($inc);
            $out .= "include $lib $c\n" unless $inc{$c}++;
        }
        for my $obj (objects($lib)) {
            for my $inc (@{$unified_info{includes}{$obj} // []}) {
                my $c = classify($inc);
                $out .= "include $lib $c\n" unless $inc{$c}++;
            }
            for my $source (@{$unified_info{sources}{$obj}}) {
                next if $source =~ /\.h$/;
                $out .= "source $lib " . classify($source) . "\n";
            }
            for my $d (@{$unified_info{defines}{$obj} // []}) {
                die "per-object define $d on $obj is not supported\n";
            }
        }
    }
    return $out;
}

sub generate {
    # Every generated header, and the generated sources the libraries compile.
    my %wanted = map { $_ => 1 } grep { /\.h$/ } keys %{$unified_info{generate}};
    for my $lib (@libs) {
        for my $obj (objects($lib)) {
            for my $source (@{$unified_info{sources}{$obj}}) {
                $wanted{$source} = 1 if $unified_info{generate}{$source};
            }
        }
    }
    # Headers first: some generators include generated headers.
    for my $file (sort { ($a =~ /\.h$/ ? 0 : 1) <=> ($b =~ /\.h$/ ? 0 : 1) || $a cmp $b } keys %wanted) {
        generate_one($file);
    }
}

sub generate_one {
    my ($file) = @_;
    my ($gen0, @args) = @{$unified_info{generate}{$file}};
    make_path(dirname($file));
    my $cc = $ENV{CC} // 'cc';
    # What the Makefile's shell would do with the arguments: expand the
    # variables the generators need, and drop the quoting.
    for (@args) {
        s/\$\(CC\)/$cc/g;
        s/\$\(PLATFORM\)/$target/g;
        s/\$\([A-Z_]+\)//g;
        s/^"(.*)"$/$1/;
        s/\s+$//;
    }
    if ($gen0 =~ /\.in$/) {
        # The Makefile's dofile rule: configdata plus the .pm dependencies.
        my (@incs, @mods);
        for my $dep ('configdata.pm', @{$unified_info{depends}{$file} // []}) {
            if ($dep =~ /\|/) {
                my ($inc, $mod) = ($`, $');
                $mod =~ s/\.pm$//;
                $mod =~ s|/|::|g;
                push @incs, "-I$inc" if $inc;
                push @mods, "-M$mod";
            } elsif ($dep =~ /\.pm$/) {
                push @incs, '-I' . dirname($dep);
                push @mods, '-M' . basename($dep, '.pm');
            }
        }
        my %seen;
        run_to($file, $^X, (grep { !$seen{$_}++ } @incs), @mods,
               catfile($src, 'util', 'dofile.pl'), "-o$target{build_file}", $gen0, @args);
    } elsif ($gen0 =~ /\.pl$/ && $file =~ /\.(s|S)$/) {
        # perlasm: flavour, then the output file.
        run($^X, $gen0, @args, $target{perlasm_scheme} // 'void', $file);
    } elsif ($gen0 =~ /\.pl$/) {
        run_to($file, $^X, $gen0, @args);
    } else {
        die "no rule to generate $file from $gen0\n";
    }
}

sub run {
    system(@_) == 0 or die "failed: @_\n";
}

sub run_to {
    my ($file, @argv) = @_;
    my $pid = open(my $out, '-|') // die "fork: $!\n";
    if ($pid == 0) { exec(@argv) or die "exec: $!\n" }
    local $/;
    my $text = <$out>;
    close($out) or die "failed: @argv\n";
    spit($file, $text);
}

sub slurp {
    open(my $fh, '<', $_[0]) or die "$_[0]: $!\n";
    local $/;
    return <$fh>;
}

sub spit {
    open(my $fh, '>', $_[0]) or die "$_[0]: $!\n";
    print $fh $_[1];
}
