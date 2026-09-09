{
  description = "lab-ansible dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: (pkg.pname or "") == "terraform";
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "lab-ansible";

          buildInputs = with pkgs; [
            ansible
            python3
            openssh
            terraform
            pass
            gnupg
            sshpass
          ];

          shellHook = ''
            echo "lab shell: ansible $(ansible --version | head -n1)"
          '';
        };
      });
}
