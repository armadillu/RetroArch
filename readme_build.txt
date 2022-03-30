#building retroarch
# on a rpi zero

sudo apt-get install ccache 
sudo apt-get install -y libgbm-dev libdrm-common libdrm-dev libdrm2 libegl1-mesa-dev git libv4l-dev libxkbcommon-dev libxml2-dev yasm zlib1g-dev libasound2-dev libudev-dev libsystemd-dev

git clone git@github.com:libretro/RetroArch.git

CFLAGS="-mtune=cortex-a53 -Ofast -march=armv8-a+crc -mfpu=neon-fp-armv8" CXXFLAGS="-march=armv8-a+crc -mfpu=neon-fp-armv8 -mtune=cortex-a53  -Ofast" ./configure --disable-caca --disable-jack --enable-opengl1 --disable-oss --disable-sdl --disable-sdl2 --disable-videocore --disable-vulkan --disable-wayland --disable-x11 --enable-alsa --enable-egl --enable-floathard --enable-kms --enable-neon --disable-opengles --disable-opengles3 --disable-pulse --enable-udev; 

make HAVE_LAKKA=0 HAVE_BLUETOOTH=0 -j2 -s

## build cores

git clone git@github.com:libretro/libretro-super.git
cd libretro-super

./libretro-fetch.sh fbneo mame2003_plus fbalpha2012_cps1 fbalpha2012_cps2 fbalpha2012_neogeo
CFLAGS="-march=native -mtune=native -s -O2" CXXFLAGS="-march=native -mtune=native -s -O2" CXX=" g++ -s -O2" CC=" gcc -s -O2"  ./libretro-build.sh fbneo mame2003_plus fbalpha2012

cp dist/unix/* ~/.config/retroarch/cores
