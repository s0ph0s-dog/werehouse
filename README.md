# Werehouse

A personal, web-based art archiving tool built on [Redbean](https://redbean.dev).

# Goals

1. Archive artwork on your own computer with proper attribution and tagging, so that you can find it again and know who created it.
2. Make it easy to share artwork with proper attribution, so that other people can find the artist and support them!
3. Be small and easy to self-host.
4. Be user-friendly.
5. Support as many modern platforms as reasonably possible.
6. Give users of the system control over their data.

# Anti-goals

1. Scalability. If your usage of this tool encounters scaling problems, you're likely using it with too many other people.
2. Productizablity. This tool is built to fix a problem I had. I don't want to turn it into a product or service.

# Setup

Check [Releases](https://github.com/s0ph0s-dog/werehouse/releases) for pre-built binaries.

1. Clone a copy of [my fork of the Cosmopolitan repository](https://github.com/s0ph0s-dog/cosmopolitan). Check out the branch `s0ph0s-patches`. Build `o//tool/net/redbean`.  I have added additional functionality to Redbean to support encoding/decoding image files and performing image content hash calculations.  If you don't want to use these features, you can edit the Makefile to use `redbean-3.0.com` instead, and it will automatically download the latest release for you.
2. Copy the compiled `redbean` to the checkout of this repository as `./redbean-3.0beta.com`
3. Run `make` to zip the project files into `werehouse.com`
4. Set the following environment variables:
   - `TZ=UTC` — The code assumes that SQLite's `strftime('', 'now')` function will produce times in UTC, which is only the case when TZ variable is set to UTC.
   - `SESSION_KEY=(32 random bytes, base64 encoded)` — A key to use for encrypting session cookies. If you don't provide one, Werehouse will generate a new one on each run, which invalidates everyone's session cookies. Run Werehouse once to make it print a key to the log for you, or generate one with `dd if=/dev/urandom bs=32 count=1 status=none | base64`
   - `FUZZYSEARCH_API_KEY=(API key for FuzzySearch, if you have one)` — Enable looking up image URLs and raw image files with [FuzzySearch](https://fuzzysearch.net), the backend that powers [FoxBot](https://syfaro.net/blog/foxbot/).
   - `FA_AUTH_COOKIES="a=(a cookie); b=(b cookie)"` — Enable scraping from [FurAffinity](https://www.furaffinity.net).
   - `TG_BOT_TOKEN=(Telegram bot token, if you have one)` — Enable a [Telegram](https://telegram.org) bot for enqueuing images and sharing records.
   - `WEASYL_API_KEY=(Weasyl API key)` — Set this to enable archiving from Weasyl. You can obtain an API key by going to [Weasyl’s API key settings page](https://www.weasyl.com/control/apikeys), which requires an account.
   - `IB_USERNAME=(Inkbunny username)` — Your Inkbunny username. Set this to enable archiving from Inkbunny.  Before this will work, you need to go to [your Inkbunny account settings page](https://inkbunny.net/account.php) and check “Enable API Access.”
   - `IB_PASSWORD=(Inkbunny password)` — Your Inkbunny password. Set this to enable archiving from Inkbunny.
   - `E621_USERNAME=(e621 Username)` — Your e621 username. Set both this and `E621_API_KEY` to enable archiving of e621 posts *which are only visible to logged-in users.* Most posts are visible without an API key.
   - `E621_API_KEY=(e621 API key)` — Your e621 API key.  Generate this by going to [the e621 control panel](https://e621.net/users/home) and clicking “Manage API Access.”
5. Run `./werehouse.com -D . -p 8082`.
6. Use the URL printed to the console on startup to register the first account.

# Nix Flake Setup

Use of a secrets management tool like [sops-nix](https://github.com/Mic92/sops-nix) (shown below) or [age-nix](https://github.com/ryantm/agenix) is highly recommended, but you can also set your apikeys in `systemd.services.werehouse.environment={}`

```nix
{
  inputs.werehouse.url = "github:s0ph0s-dog/werehouse";
  inputs.werehouse.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, werehouse }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sops-nix.nixosModules.sops
        {config, ...}: {
          services.werehouse = {
            enable = true;
            dataDir = "/var/lib/werehouse";
            enableNginxVhost = true;
            publicDomainName = "werehouse.s0ph0s.dog";
            # port = 8082;
            # verboseLevel = 2;
          };
          systemd.services.werehouse.serviceConfig = config.sops.secrets."werehouse.env".path;
          sops.secrets."werehouse.env".sopsFile = secrets/werehouse.yaml;
        }
      ];
    };
  };
}
```

`$ sops secrets/werehouse.yaml`
```yaml
werehouse.env: |-
  SESSION_KEY=abcDEFghiJKL=
  TG_BOT_TOKEN=1234567890:AaBbCcDd_EeFfGgHh
  # etc
```

# Contributing

Contributions are welcome, as long as they don't draw the project away from its goals. Open issues or pull requests as you like!

# License

ISC, like Redbean and Cosmopolitan. Code in the `lib/third_party` folder is from other places, and is subject to different license requirements. The original source is linked at the top of each module.
