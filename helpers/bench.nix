{ snabbSrc ? (builtins.fetchTarball https://github.com/snabbco/snabb/tarball/next)
# specify how many times is each benchmark ran
, numTimesRunBenchmark ? 20
# specify on what hardware will the benchmarks be ran
, requiredSystemFeatures ? [ "performance" ]
, SNABB_PCI0 ? "0000:01:00.0"
, SNABB_PCI_INTEL0 ? "0000:01:00.0"
, SNABB_PCI_INTEL1 ? "0000:01:00.1"
, nixpkgs ? null
}:
with (import (if nixpkgs == null then fetchTarball https://github.com/NixOS/nixpkgs/archive/d3456dc1e490289094684f97648c6180ee1cc0f0.tar.gz else nixpkgs) {});
with lib;
with (import ../lib.nix);

let
  snabb = import "${snabbSrc}" {};
  defaults = {
    inherit requiredSystemFeatures SNABB_PCI0 SNABB_PCI_INTEL0 SNABB_PCI_INTEL1 snabb;
    times = numTimesRunBenchmark;
    installPhase = ''
      if test -d state; then
        /var/setuid-wrappers/sudo chown -R $(whoami) state
        tar cfJ $out/state.tar.xz state
      fi
    '';
    alwaysSucceed = true;
  };
  snabbBenchTestBasic = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-basic1-100e6";
    checkPhase = ''
      export SNABB_SHM_ROOT=state
      /var/setuid-wrappers/sudo -E ${snabb}/bin/snabb snabbmark basic1 100e6 |& tee $out/log.txt
    '';
  });
  snabbBenchTestPacketblaster64 = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-packetblaster-64";
    checkPhase = ''
      cd src
      export SNABB_SHM_ROOT=state
      /var/setuid-wrappers/sudo -E ${snabb}/bin/snabb packetblaster replay --duration 1 \
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
      export SNABB_SHM_ROOT=state
      /var/setuid-wrappers/sudo -E program/snabbnfv/selftest.sh bench |& tee $out/log.txt
    '';
  });
  snabbBenchTestNFVJumbo = mkSnabbBenchTest (defaults // {
    name = "${snabb.name}-nfv-jumbo";
    needsTestEnv = true;
    checkPhase = ''
      cd src
      export SNABB_SHM_ROOT=state
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
  # Fields: benchmark,id,score,unit
  writeCSV = drv: benchName: unit:
               ''if test -z "$score"; then score="NA"; fi
                 echo ${benchName},${toString drv.numRepeat},$score,${unit} >> $out/bench.csv'';
  toCSV = {
    basic = benchName: drv: ''
      score=$(awk '/Mpps/ {print $(NF-1)}' < ${drv}/log.txt)
    '' + writeCSV drv benchName "Mpps";
    blast = benchName: drv: ''
      pps=$(cat ${drv}/log.txt | grep TXDGPC | cut -f 3 | sed s/,//g)
      score=$(echo "scale=2; $pps / 1000000" | bc)
    '' + writeCSV drv benchName "Mpps";
    iperf = benchName: drv: ''
      cat ${drv}/log.txt
      score=$(awk '/^IPERF-/ { print $2 }' < ${drv}/log.txt)
    '' + writeCSV drv benchName "Gbps";
    dpdk = benchName: drv: ''
      score=$(awk '/^Rate\(Mpps\):/ { print $2 }' < ${drv}/log.txt)
    '' + writeCSV drv benchName "Mpps";
  };

  benchmark-csv = runCommand "snabb-performance-csv"
    { buildInputs = [ pkgs.gawk pkgs.bc ];
      preferLocalBuild = true; }
  ''
    mkdir $out
    echo "benchmark,id,score,unit" > $out/bench.csv
    ${concatMapStringsSep "\n" (toCSV.basic "basic1")    snabbBenchTestBasic}
    ${concatMapStringsSep "\n" (toCSV.blast "blast64")   snabbBenchTestPacketblaster64}
    ${concatMapStringsSep "\n" (toCSV.blast "blastS64")  snabbBenchTestPacketblasterSynth64}
    ${concatMapStringsSep "\n" (toCSV.iperf "iperf1500") snabbBenchTestNFV}
    ${concatMapStringsSep "\n" (toCSV.iperf "iperf9000") snabbBenchTestNFVJumbo}
    ${concatMapStringsSep "\n" (toCSV.dpdk  "dpdk64")    snabbBenchTestNFVPacketblaster}
  '';

  benchmark-report = runCommand "snabb-performance-report"
    { preferLocalBuild = true;
      buildInputs = [ benchmark-csv rPackages.rmarkdown rPackages.ggplot2 R pandoc which ]; }
  ''
    mkdir -p $out/nix-support

    ${concatMapStringsSep "\n" (drv: "cat ${drv}/log.txt > $out/${drv.benchName}-${toString drv.numRepeat}.log") benchmarks}

    tar cfJ logs.tar.xz -C $out .

    mv logs.tar.xz $out/
    echo "file tarball $out/logs.tar.xz" >> $out/nix-support/hydra-build-products

    # Create markdown report
    cp ${./report.Rmd} ./report.Rmd
    cp ${benchmark-csv}/bench.csv .
    cat bench.csv
    cat report.Rmd
    echo "library(rmarkdown); render('report.Rmd')" | R --no-save
    cp report.html $out
    echo "file HTML $out/report.html"  >> $out/nix-support/hydra-build-products
    echo "nix-build out $out" >> $out/nix-support/hydra-build-products
  '';

in {
 inherit benchmark-csv;
 inherit benchmark-report;
} // (builtins.listToAttrs (map (attrs: nameValuePair attrs.name attrs) benchmarks))
