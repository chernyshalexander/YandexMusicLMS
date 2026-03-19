# Testing with API Tokens

## IMPORTANT: Never commit tokens to the repository!

The `token.txt` file is in `.gitignore` and must NEVER be committed.

## Setting up your test token

1. Create `test/token.txt` with your Yandex Music API token:
   ```bash
   echo "your-api-token-here" > test/token.txt
   ```

2. Verify it's in `.gitignore`:
   ```bash
   git check-ignore -v test/token.txt
   # Should output: test/token.txt
   ```

## Using the token in test scripts

### Option 1: Using TokenHelper module (RECOMMENDED)

```perl
#!/usr/bin/perl
use strict;
use warnings;
use lib "/home/chernysh/Projects/yandex";
use test::TokenHelper;

my $token = TokenHelper::get_token()
    or die "No token configured in test/token.txt\n";

# Use token in your tests
my $client = Plugins::yandex::ClientAsync->new($token);
```

### Option 2: Manual token reading

```perl
my $token = do {
    open my $fh, '<', 'test/token.txt' or die "Cannot open token.txt: $!";
    my $content = do { local $/; <$fh> };
    chomp($content);
    $content;
};
```

### Option 3: Environment variable

```bash
export YANDEX_TOKEN=$(cat test/token.txt)
```

Then in your script:
```perl
my $token = $ENV{YANDEX_TOKEN} or die "YANDEX_TOKEN not set\n";
```

## Security Checklist

- [ ] Token file is in `.gitignore`
- [ ] Token is never hardcoded in scripts
- [ ] Token file is in `.gitignore` (double-check!)
- [ ] Use `TokenHelper` or environment variable approach
- [ ] Before committing, verify no tokens in git: `git grep -i "token.*[a-z0-9]{20,}"`

## Verifying token safety before commit

```bash
# Check if any files contain token patterns
git diff --cached | grep -i "oauth\|token" | grep -v "test/token.txt"

# Verify token.txt is not staged
git status | grep token.txt
```
