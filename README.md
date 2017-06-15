# Modern Secrets Management

This repository contains the opening materials and a rough outline for my
[2017 Cloud Foundry + HashiCorp Vault][talk] which discusses using Vault and
Cloud Foundry together.

This outline was written in advance of the presentation, so questions or
digressions may not be captured here in the fullest.

These configurations use Vault 0.7.3, but the concepts are largely applicable to
all Vault releases.

Finally **these are not best practice Terraform configurations. These are for
demonstration purposes only and should not be used in production.**

## In Advance

- `ssh-add`
- Make sure 1password is unlocked and on the "Demo Vault" vault
- SSH into the demo instance

## Getting Started

I have configured a Vault server in advance that is already running and
listening. We can check the status of the Vault server by running:

```shell
$ vault status
```

It looks like we are ready to go!

## Authenticating

The first thing we need to do is authenticate to Vault. For this demo, we will
login via the root user. This is not a best practice.

```
$ vault auth root
```

There are many ways to authenticate to Vault including GitHub,
username-password, LDAP, and more. There are also ways for machines to
authenticate such as AppID or TLS.

The root user is special and has all permissions in the system. Other users must
be granted access via policies, which we will explore in a bit.

## Static Secrets

As mentioned, Vault can act as encrypted redis/memcached. This data is encrypted
in transit and at rest, and Vault stores the data.

```
$ vault write secret/foo value=super-secret
```

This mount supports basic CRUD operations:

```
$ vault read secret/foo
```

```
$ vault write secret/foo value=new-value
```

```
$ vault list secret/
```

```
$ vault delete secret/foo
```

## Semi-Static Secrets

Vault can also provide encryption as a service. In this model, Vault encrypts
the data, but it does not _store_ it. Instead the encrypted data is returned in
the response, and it is the caller's responsibility to store the data (perhaps
in a database).

The advantage here is that applications do not need to know how to do asymmetric
encryption nor do they applications even know the encryption key. An attacker
would need to compromise multiple systems to decrypt the data.

The provisioning script creates a key named `my-app`. This key is like a
symbolic link to an encryption key or set of encryption keys. The transit
backend supports key rotation and upgrading, so the name is a human identifier
around that.

We can feed data into this named key, and Vault will return the encrypted
data. Because there is no requirement the data be "text", we need to pass
base64-encoded data.

```
$ vault write transit/encrypt/my-app plaintext=$(base64 <<< "foo")
```

Vault returns the base64-encoded ciphertext. This ciphertext can be stored in
our database or filesystem. When our application needs the plaintext value, it
can post the encrypted value and get the plaintext back.

```
$ vault write transit/decrypt/my-app ciphertext="..."
```

And then `base64 -d` that value.

```
$ base64 -d <<< "..."
```

The transit endpoint also supports "derived" keys, which enables each piece of
data to be encrypted with a unique "context". This context generates a new
encryption key. Each record then has a unique encryption key, but Vault does not
have the overhead of managing millions of encryption keys because they are
derived from a parent key.

Example: rows in a database

## Dynamic Secrets

### PostgreSQL

Vault also has the ability to _generate_ secrets. These are called "dynamic"
secrets. Unlike static secrets, dynamic secrets have an expiration, called a
lease. At the end of this lease, the credential is revoked. This prevents secret
sprawl and significantly reduces the attack surface. Instead of a database
password living in a text file for 6 months, it can be dynamically generated
every 30 minutes!

I've configured everything in advance, so when we read from the proper path,
Vault will make a connection to postgres, generate a credential using the SQL I
provided, and return it to me. Future requests to the database are made directly
to postgres (Vault is not a pass-through for db connections).

```
$ vault read database/creds/readonly
```

These are real postgresql credentials. We can login to postgres to verify:

```
$ psql -U postgres
```

Each time I read from this endpoint, Vault dynamically generates a new
credential.

```
$ vault read database/creds/readonly
```


### AWS IAM

Vault can do more than generate database credentials - it can also communicate
with third-party APIs to generate credentials, such as AWS IAM.

Again, I configured this in advance. Vault can map policies to roles, so you
write policies like:

> Anyone on the "developers" GitHub team can generate read-only AWS credentials
that are valid for 15 minutes.

When we read from this endpoint, Vault will connection to AWS and generate an
IAM pair, returning the result to the terminal.

```
$ vault read aws/creds/user
```

These leases seem long - let's fix that.

```
$ vault write aws/config/lease lease=30s lease_max=5m
```

Now create another user and observe the lease_duration field

```
$ vault read aws/creds/user
```

We can also revoke all these credentials, perhaps in a break glass scenario:

```
$ vault revoke -prefix aws/
```

### Certificate Authority

Vault can also be used as a full certificate authority (CA).

The PKI backend requires a pre-existing cert and a decent understanding of PKI
principles. For the purposes of this demo, we'll cheat and encapsulate that
logic in a script.

We can generate a certificate for a given common name:

```
$ vault write pki/issue/my-website common_name="www.sethvargo.com"
```

Because these are just API requests under the hood, it is possible to make API
requests, retrieve certificates, and only persist them in-memory.

### TOTP Generator

A recent feature in Vault is the ability to generate OTP codes, such as MFA
codes or 2FA codes. In this way, it could be used to replace something like
Google Authenticator or Authy. First we mount the backend:

Read from this endpoint at any point in time to get the OTP code.

```
$ vault read totp/code/demo
```

### TOTP Authenticator

Vault can also act as a TOTP provider:

```
$ vault write totp/keys/my-app \
    generate=true \
    issuer=Vault \
    account_name=seth@sethvargo.com
```

This will return two results - a base64-encoded barcode and a URL. Either of
these may be used with a password manager. I'll use 1Password.

To generate the image, copy it to your clipboard. then decode it into a file
_on the local system_.

```
$ base64 --decode <<< "..." > qr.png

$ open qr.png
```

Now I'll open up 1Password and create a new login and scan this code.

And then we can validate the code:

```
$ vault write totp/code/my-app code=127388
```

## Broker

Our broker is going to talk to the instance of Vault we've been using. The
broker does not require full management of the system.

```sh
$ cat scripts/setup-env.sh
# ...

$ source scripts/setup-env.sh
```

Next create a new org and space

```sh
$ cf target -o demo -s vault-broker
```

Clone down the broker so we can push it up

```sh
$ git clone https://github.com/hashicorp/cf-vault-broker
```

And push

```sh
$ pushd cf-vault-broker
$ cf push --random-route --no-start
$ popd
```

Configure the broker via envvars:

```sh
$ cat scripts/cf-set-env.sh
# ...

$ ./scripts/cf-set-env.sh
```

And now start it

```sh
$ cf start vault-broker
```

Verify it's running

```sh
$ cf apps
```

Get the randomly assigned URL (demo note: probably just easier to copy-paste
from previous output).

```sh
CF_BROKER_URL="..."
```

Check that our service is, in fact, offered:

```
$ curl -s "${CF_USERNAME}:${CF_PASSWORD}@${CF_BROKER_URL}/v2/catalog" | jq .
```

Next we need to register the broker with CF (emphasize that this broker could be
running in any other service)

```sh
$ cf target -s example
```

Now create the service broker

```sh
$ cf create-service-broker vault-broker "${CF_USERNAME}" "${CF_PASSWORD}" "https://${CF_BROKER_URL}" --space-scoped
```

See if the broker is in the marketplace

```sh
$ cf marketplace
```

Let's start an instance of our broker

```sh
$ cf create-service hashicorp-vault shared demo-vault
```

Check if it's running

```sh
$ cf services
```

(Optional, show logs on Vault server with `sudo journalctl -fu vault`)

Let's start up a silly demo app that just echos an envvar:

```sh
$ pushd cf-demo-app
$ cf push --health-check-type process
$ popd
```

Show the current env

```sh
$ cf env demo-app
```

Bind to the broker to create the policy and token and populate `VCAP_SERVICES`.

```sh
$ cf bind-service demo-app demo-vault
```

Verify the envvar is populated

```sh
$ cf env demo-app
```

Restage and check logs

```sh
$ cf restage demo-app
$ cf logs demo-app --recent
```

The envvar `VCAP_SERVICES` contains the JSON payload of our Vault token and all
the paths we need to communicate with Vault.

Time permitting, we can simulate reading and writing secrets using this data.

```
$ vault auth <token>
$ vault write cf/<id>/secret/foo a=b c=d
```
