#!/usr/bin/env bash

# if systemd is used and you need sound, login to $console prior https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=747882
# if you can't stand cursor bug, start this script from console, not another X https://bugs.launchpad.net/ubuntu/+source/plasma-workspace/+bug/1684240


### configuration ###
display=1
console=1
tmpdir=$XDG_RUNTIME_DIR/nvidia
# see alternative packages with "nix-instantiate --eval -E 'with import <nixpkgs> {}; linuxPackages.nvidiaPackages'"
package="linuxPackages.nvidia_x11"

function nixbuildnamed()
{
    OUT="$tmpdir/built_$1"
    rm -f $OUT
    shift
    echo nix-build "$@" --out-link $OUT  >&2
    nix-build "$@" --out-link $OUT 
}

busid=$($(nixbuildnamed pciutils '<nixpkgs>' -A pciutils)/bin/lspci | awk '/VGA compatible controller: NVIDIA /{gsub(/\./,":",$1); print $1}')
kernel="$(uname -r)"

XF86INPUTLIBINPUT=$(nixbuildnamed xf86inputlibinput '<nixpkgs>' -A xorg.xf86inputlibinput)
NVIDIA_X11=$(nixbuildnamed package '<nixpkgs>' -A $package.bin)

mkdir -p $tmpdir/modules
cat > $tmpdir/xorg.conf << EOF
Section "Files"
  ModulePath "$XF86INPUTLIBINPUT/lib/xorg/modules/input"
  ModulePath "$NVIDIA_X11/lib/xorg/modules"
  ModulePath "$tmpdir/modules"
EndSection

Section "InputClass"
  Identifier "libinput pointer catchall"
  MatchIsPointer "on"
  MatchDevicePath "/dev/input/event*"
  Driver "libinput"
EndSection
Section "InputClass"
  Identifier "libinput keyboard catchall"
  MatchIsKeyboard "on"
  MatchDevicePath "/dev/input/event*"
  Driver "libinput"
EndSection
Section "InputClass"
  Identifier "libinput touchpad catchall"
  MatchIsTouchpad "on"
  MatchDevicePath "/dev/input/event*"
  Driver "libinput"
  Option "Tapping" "on"
  Option "DisableWhileTyping" "off"
  Option "MiddleEmulation" "on"
EndSection

Section "Module"
  Load "modesetting"
EndSection
Section "Device"
  Identifier "nvidia"
  Driver "nvidia"
  BusID "$busid"
  Option "AllowEmptyInitialConfiguration"
EndSection
EOF
### end of configuration ###

red='\033[0;31m'
if [ ! -d $tmpdir ]; then
  echo -e "$red Given tmpdir doesn't exist"
  exit 1
fi
if [ "$1" == "" ]; then
  echo -e "$red Give path to game as argument"
  exit 1
fi
if [ "$busid" == "" ]; then
  echo -e "$red No Optimus card found"
  exit 1
fi
# module nvidia_drm is in use
if [ "$(sudo fgconsole)" == "$console" ]; then
  echo -e "$red You need to run $0 from another console"
  exit 1
fi
if [ -z "$XAUTHORITY" ]; then
  export XAUTHORITY=$HOME/.Xauthority
fi

XRANDR=$(nixbuildnamed xrandr '<nixpkgs>' -A xorg.xrandr)

NVIDIA_LIBS=$(nixbuildnamed nvidia_libs -E '
  with import <nixpkgs> {};

  buildEnv {
    name = "nvidia-libs";
    paths = [
      libglvnd
      ('$package'.override {
        libsOnly = true;
        kernel = null;
      })
    ];
  }
')

NVIDIA_LIBS32=$(nixbuildnamed nvidia_libs32 -E '
    with import <nixpkgs> {};

    buildEnv {
      name = "nvidia-libs-32";
      paths = with pkgsi686Linux; [
        libglvnd
        ('$package'.override {
          libsOnly = true;
          kernel = null;
        })
      ];
  }
')


NVIDIA_X11_LIBS_ONLY=$(nixbuildnamed nvidia_x11_libs_only -E '
  with import <nixpkgs> {};

  '$package'.override {
    libsOnly = true;
    kernel = null;
  }
')

LIBGLVND=$(nixbuildnamed '<nixpkgs>' -A libglvnd)

cat > $tmpdir/session << EOF
#!/usr/bin/env bash
$XRANDR/bin/xrandr --setprovideroutputsource modesetting NVIDIA-0
$XRANDR/bin/xrandr --auto
export LD_LIBRARY_PATH="$NVIDIA_LIBS/lib`
  `:$NVIDIA_LIBS32/lib"
#export PATH="\$(nix-build --no-out-link -E '
#  with import <nixpkgs> {};
#
#  buildEnv {
#    name = "nvidia-bin";
#    paths = [ '$package'.settings '$package'.bin ];
#  }
#')/bin:\$PATH"
export VK_ICD_FILENAMES=$NVIDIA_X11_LIBS_ONLY/share/vulkan/icd.d/nvidia.json";
export OCL_ICD_VENDORS=$NVIDIA_X11_LIBS_ONLY/etc/OpenCL/vendors/nvidia.icd";
# https://bugzilla.gnome.org/show_bug.cgi?id=774775
export GDK_BACKEND=x11
$@
EOF
chmod +x $tmpdir/session

# switch user
cat > $tmpdir/wrapper << EOF
#!/bin/sh
sudo chown $USER $XAUTHORITY
sudo -u $USER $tmpdir/session
EOF
chmod +x $tmpdir/wrapper

X_DIR=$(nixbuildnamed X '<nixpkgs>' -A xorg.xorgserver)

# dixRegisterPrivateKey: Assertion `!global_keys[type].created' failed
cat > $tmpdir/X << EOF
#!/bin/sh
LD_LIBRARY_PATH="$LIBGLVND/lib"
exec $X_DIR/bin/X "\$@"
EOF
chmod +x $tmpdir/X

get_major_version()
{
  kernel_compile_h=$1
  kernel_cc_string=`cat ${kernel_compile_h} | grep LINUX_COMPILER | cut -f 2 -d '"'`
  kernel_cc_version=`echo ${kernel_cc_string} | grep -o '[0-9]\+\.[0-9]\+' | head -n 1`
  kernel_cc_major=`echo ${kernel_cc_version} | cut -d '.' -f 1`
}

if [ -e /etc/nixos ]; then
    # complicated to always check non-nixos rules on nixos
  bbswitch="$(nixbuildnamed bbswitch -E '
    with import <nixpkgs/nixos> {};

    let
      custom = config.boot.kernelPackages;
      default = pkgs.linuxPackages;
    in default.bbswitch.override {
      kernel = default.kernel // {
        modDirVersion = "'$kernel'";
        inherit (custom.kernel) dev;
      };
    }
  ')"
  nvidia="$(nixbuildnamed nvidia -E '
    with import <nixpkgs/nixos> {};

    let
      custom = config.boot.kernelPackages;
    in (pkgs.'$package'.overrideAttrs (oldAttrs: rec {
      kernelVersion = "'$kernel'";
      kernel = custom.kernel.dev;
    })).bin
  ')"
else
  bbswitch="$(nixbuildnamed bbswitch -E '
    with import <nixpkgs> {};

    let
      default = linuxPackages;
    in default.bbswitch.override {
      kernel = default.kernel // {
        modDirVersion = "'$kernel'";
        dev = "";
      };
    }
  ')"
  # needed for arch
  sudo ln -s /lib/modules/$kernel/build /lib/modules/$kernel/source
  get_major_version /lib/modules/$kernel/source/include/generated/compile.h
  nvidia="$(nixbuildnamed nvidia -E '
    with import <nixpkgs> {};

    (('$package'.override { stdenv = overrideCC stdenv gcc'$kernel_cc_major'; }).overrideAttrs (oldAttrs: rec {
      kernelVersion = "'$kernel'";
      kernel = "";
      NIX_ENFORCE_PURITY = 0;
    })).bin
  ')"
fi

sudo insmod $bbswitch/lib/modules/$kernel/misc/bbswitch.ko
sudo tee /proc/acpi/bbswitch <<<ON

sudo modprobe ipmi_devintf
for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm
do
  sudo insmod $nvidia/lib/modules/$kernel/misc/$m.ko
done

# https://bugs.freedesktop.org/show_bug.cgi?id=94577
ln -sf $(nixbuildnamed xorgserver '<nixpkgs>' -A xorg.xorgserver)/lib/xorg/modules/* $tmpdir/modules
rm $tmpdir/modules/libglamoregl.so

xinit=$(nixbuildnamed xinit '<nixpkgs>' -A xorg.xinit)/bin
# xinit is unsecure
sudo PATH=$xinit:$PATH $xinit/startx $tmpdir/wrapper -- $tmpdir/X :$display -config $tmpdir/xorg.conf -logfile $tmpdir/X.log vt$console
sudo chown $USER $XAUTHORITY

for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia
do
  sudo rmmod $m
done
sudo tee /proc/acpi/bbswitch <<<OFF
