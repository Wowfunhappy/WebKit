# Loaded into Tools/Scripts/run-javascriptcore-tests by run-jsc-tests.sh (perl -MToolchainLipo).
#
# webkitdirs::architecturesForProducts reads the tested JavaScriptCore's architectures with
# `/usr/bin/lipo -archs`, an option 10.9's Xcode lipo lacks. This is that function with the lipo the wrapper
# names in AQUAWEBKIT_LIPO (the toolchain's cctools lipo, cctools.sh) in its place.
package ToolchainLipo;

use strict;
use warnings;
use File::Spec;
use webkitdirs ();

my $lipo = $ENV{AQUAWEBKIT_LIPO};

{
    no warnings 'redefine';
    *webkitdirs::architecturesForProducts = sub {
        return webkitdirs::architecture() if !webkitdirs::isAppleCocoaWebKit();
        my $webkitBinary = File::Spec->catdir(webkitdirs::executableProductDir(), "JavaScriptCore.framework", "JavaScriptCore");
        my $architectures = `"$lipo" -archs "$webkitBinary"`;
        chomp($architectures);
        return $architectures;
    };
}

1;
