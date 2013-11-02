#!/usr/bin/perl

# fakeldd
#
# Replacement for ldd with usage of objdump
#
# (c) 2003-2010, 2013 Piotr Roszatycki <dexter@debian.org>, LGPL

use strict;

my @Libs = ();
my %Libs = ();

my $Status = 0;
my $Dynamic = 0;
my $Format = '';

my $Ldsodir = "/lib";
my @Ld_Library_Path = qw(/usr/lib /lib /usr/lib32 /lib32 /usr/lib64 /lib64);

my $Base = $ENV{FAKECHROOT_BASE_ORIG};

sub ldso {
    my ($lib) = @_;

    return if $Libs{$lib};

    my $path;

    if ($lib =~ /^\//) {
        $path = $lib;
    }
    else {
        foreach my $dir (@Ld_Library_Path) {
            next unless -f "$dir/$lib";

            my $badformat = 0;
            local *PIPE;
            open PIPE, "objdump -p '$dir/$lib' 2>/dev/null |";
            while (my $line = <PIPE>) {
                if ($line =~ /file format (\S*)$/) {
                    $badformat = 1 unless $1 eq $Format;
                    last;
                }
            }
            close PIPE;

            next if $badformat;

            $path = "$dir/$lib";
            last;
        }
    }

    push @Libs, $lib;
    if (-f $path) {
        $path =~ s/^\Q$Base\E// if $Base;
        $Libs{$lib} = $path;
        objdump($path);
    }
}


sub objdump {
    my (@files) = @_;

    foreach my $file (@files) {
        local *PIPE;
        open PIPE, "objdump -p '$Base$file' 2>/dev/null |";

        while (my $line = <PIPE>) {
            $line =~ s/^\s+//;

            if ($line =~ /file format (\S*)$/) {
                if (not $Format) {
                    $Format = $1;

                    if ($^O eq 'linux') {
                        if ($Format =~ /^elf64-/) {
                            push @Libs, 'linux-vdso.so.1';
                            $Libs{'linux-vdso.so.1'} = '';
                        }
                        else {
                            push @Libs, 'linux-gate.so.1';
                            $Libs{'linux-gate.so.1'} = '';
                        }
                    }

                    foreach my $lib (split /[:\s]/, $ENV{LD_PRELOAD}||'') {
                        ldso($lib);
                    }
                }
                else {
                    next unless $Format eq $1;
                }
            }
            if (not $Dynamic and $line =~ /^Dynamic Section:/) {
                $Dynamic = 1;
            }

            next unless $line =~ /^ \s* NEEDED \s+ (.*) \s* $/x;

            my $needed = $1;
            if ($needed =~ /^ld(-linux)?(\.|-)/) {
                $needed = "$Ldsodir/$needed";
            }
            ldso($needed);
        }
        close PIPE;
    }
}


sub load_ldsoconf {
    my ($file) = @_;

    local *FH;
    open FH, $file;
    while (my $line = <FH>) {
        chomp $line;
        $line =~ s/#.*//;
        next if $line =~ /^\s*$/;

        if ($line =~ /^include\s+(.*)\s*/) {
            my $include = $1;
            foreach my $incfile (glob $include) {
                load_ldsoconf($incfile);
            }
            next;
        }

        unshift @Ld_Library_Path, $line;
    }
    close FH;
}


MAIN: {
    my @args = @ARGV;

    if (not @args) {
        print STDERR "fakeldd: missing file arguments\n";
        exit 1;
    }

    if (not `which objdump`) {
        print STDERR "fakeldd: objdump: command not found: install binutils package\n";
        exit 1;
    }

    load_ldsoconf('/etc/ld.so.conf');
    unshift @Ld_Library_Path, split(/:/, $ENV{LD_LIBRARY_PATH}||'');

    while ($args[0] =~ /^-/) {
        my $arg = $args[0];
        shift @ARGV;
        last if $arg eq "--";
    }

    foreach my $file (@args) {
        %Libs = ();
        $Dynamic = 0;

        if (@args > 1) {
            print "$file:\n";
        }

        if (not -f $file) {
            print STDERR "ldd: $file: No such file or directory\n";
            $Status = 1;
            next;
        }

        objdump($file);

        if ($Dynamic == 0) {
            print "\tnot a dynamic executable\n";
            $Status = 1;
        }
        elsif (scalar %Libs eq "0") {
            print "\tstatically linked\n";
        }

        my $address = '0x' . '0' x ($Format =~ /^elf64-/ ? 16 : 8);

        foreach my $lib (@Libs) {
            if (defined $Libs{$lib}) {
                printf "\t%s => %s (%s)\n", $lib, $Libs{$lib}, $address;
            }
            elsif ($lib =~ /^\//) {
                printf "\t%s (%s)\n", $lib, $address;
            }
            else {
                printf "\t%s => not found\n", $lib;
            }
        }

    }
}

END {
    $? = $Status;
}