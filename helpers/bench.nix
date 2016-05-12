{ snabbSrc ? (builtins.fetchTarball https://github.com/snabbco/snabb/tarball/next)
# specify how many times is each benchmark ran
, numTimesRunBenchmark ? 20
# specify on what hardware will the benchmarks be ran
, requiredSystemFeatures ? [ "performance" ]
, SNABB_PCI0 ? "0000:01:00.0"
, SNABB_PCI_INTEL0 ? "0000:01:00.0"
, SNABB_PCI_INTEL1 ? "0000:01:00.1"
, pkgs ? (import <nixpkgs> {})}:

with pkgs;
with lib;
with (import ../lib.nix);

let
  snabb = import "${snabbSrc}" {};
  defaults = {
    inherit requiredSystemFeatures SNABB_PCI0 SNABB_PCI_INTEL0 SNABB_PCI_INTEL1 snabb;
    times = numTimesRunBenchmark;
  };
  snabbBenchTestBasic = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-basic1-100e6";
    checkPhase = ''
      /var/setuid-wrappers/sudo ${snabb}/bin/snabb snabbmark basic1 100e6 |& tee $out/log.txt
    '';
  });
  snabbBenchTestPacketblaster64 = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-packetblaster-64";
    checkPhase = ''
      cd src
      /var/setuid-wrappers/sudo ${snabb}/bin/snabb packetblaster replay --duration 1 \
        program/snabbnfv/test_fixtures/pcap/64.pcap "${SNABB_PCI_INTEL0}" |& tee $out/log.txt
    '';
  });
  snabbBenchTestPacketblasterSynth64 = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-packetblaster-synth-64";
    checkPhase = ''
      /var/setuid-wrappers/sudo ${snabb}/bin/snabb packetblaster synth \
        --src 11:11:11:11:11:11 --dst 22:22:22:22:22:22 --sizes 64 \
        --duration 1 "${SNABB_PCI_INTEL0}" |& tee $out/log.txt
    '';
  });
  snabbBenchTestNFV = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-nfv";
    needsTestEnv = true;
    checkPhase = ''
      cd src
      /var/setuid-wrappers/sudo -E program/snabbnfv/selftest.sh bench |& tee $out/log.txt
    '';
  });
  snabbBenchTestNFVJumbo = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-nfv-jumbo";
    needsTestEnv = true;
    checkPhase = ''
      cd src
      /var/setuid-wrappers/sudo -E program/snabbnfv/selftest.sh bench jumbo |& tee $out/log.txt
    '';
  });
  snabbBenchTestNFVPacketblaster = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-nfv-packetblaster";
    needsTestEnv = true;
    checkPhase = ''
      cd src
      /var/setuid-wrappers/sudo -E timeout 120 program/snabbnfv/packetblaster_bench.sh |& tee $out/log.txt
    '';
  });

  benchmarks = flatten [
    snabbBenchTestBasic
    snabbBenchTestPacketblaster64
    snabbBenchTestPacketblasterSynth64
    snabbBenchTestNFV
    snabbBenchTestNFVJumbo
    snabbBenchTestNFVPacketblaster
  ];

  # Functions providing commands to convert logs to CSV
  toCSV = {
    basic = name: drv: ''
      awk '/Mpps/ {print $(NF-1)}' < ${drv}/log.txt >> $out/${name}.csv
    '';
    blast = name: drv: ''
      pps = $(cat ${drv}/log.txt | grep TXDGPC | cut -f 3 | sed s/,//g
      echo "scale=2; $pps / 1000000" | bc >> $out/${name}.csv'
    '';
    iperf = name: drv: ''
      awk '/^IPERF-1500/ { print $2 } >> $out/${name}.csv
    '';
    dpdk = name: drv: ''
      awk '/^Rate(Mpps):/ { print $2 } >> $out/${name}.csv
    '';
  };

  benchmark-csv = runCommand "snabb-performance-csv"
    { buildInputs = [ pkgs.gawk pkgs.bc ];
      preferLocalBuild = true; }
  ''
    ${concatMapStringsSep "\n" (toCSV.basic "basic1")    snabbBenchTestBasic}
    ${concatMapStringsSep "\n" (toCSV.blast "pb64")      snabbBenchTestPacketblaster64}
    ${concatMapStringsSep "\n" (toCSV.blast "pbS64")     snabbBenchTestPacketblasterSynth64}
    ${concatMapStringsSep "\n" (toCSV.iperf "iperf1500") snabbBenchTestNFV}
    ${concatMapStringsSep "\n" (toCSV.iperf "iperf9000") snabbBenchTestNFVJumbo}
    ${concatMapStringsSep "\n" (toCSV.dpdk  "dpdk64")    snabbBenchTestNFVPacketblaster}
  '';

  benchmark-report = runCommand "snabb-performance-final-report" { preferLocalBuild = true; } ''
    mkdir -p $out/nix-support

    ${concatMapStringsSep "\n" (drv: "cat ${drv}/log.txt > $out/${drv.benchName}-${toString drv.numRepeat}.log") benchmarks}

    tar cfJ logs.tar.xz -C $out .

    for f in $out/*; do
      echo "file log $f" >> $out/nix-support/hydra-build-products
    done

    mv logs.tar.xz $out/
    echo "file tarball $out/logs.tar.xz" >> $out/nix-support/hydra-build-products
  '';
in {
 inherit benchmark-csv;
 inherit benchmark-report;
} // (builtins.listToAttrs (map (attrs: nameValuePair attrs.name attrs) benchmarks))
