
############################# Secrets from the bank's CyberArk Conjur #############################
config.providers=cyberark
config.providers.cyberark.class=io.confluent.csid.config.provider.cyberark.CyberArkConfigProvider
config.providers.cyberark.param.cyberark.url=${VAULT_URL}
config.providers.cyberark.param.cyberark.account=${VAULT_ACCOUNT}
config.providers.cyberark.param.cyberark.auth.username=host/${VAULT_POLICY}/${HOST_SHORT}
config.providers.cyberark.param.cyberark.auth.apikey=${CONJUR_API_KEY}
config.providers.cyberark.param.polling.enabled=false
