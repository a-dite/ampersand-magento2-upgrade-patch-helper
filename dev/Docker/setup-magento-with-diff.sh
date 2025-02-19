#!/bin/bash
source /root/.bashrc
set -euo pipefail
cd /src/dev
export COMPOSER_MEMORY_LIMIT=4G

HOSTNAME='host.docker.internal'
if [ ! "$NODB" == "0" ]; then
  echo "Setting up project without a database"
else
  # https://stackoverflow.com/a/61831812/4354325
  if ! getent ahosts $HOSTNAME; then
    IP=$(ip -4 route list match 0/0 | awk '{print $3}')
    echo "Host ip is $IP"
    echo "$IP   $HOSTNAME" | tee -a /etc/hosts
  fi
  getent ahosts $HOSTNAME
  echo "done"
fi

# Configure local database and directory
if test -d ./instances/magento$ID; then
  echo "rm -rf ./instances/magento$ID"
  rm -rf ./instances/magento$ID
fi

echo "ensuring we have necessary php versions"
phpenv global $PHP_TO && php --version
phpenv global $PHP_FROM && php --version

echo "setting php to version $PHP_FROM"
phpenv global $PHP_FROM

# Prepare composer project
# See https://store.fooman.co.nz/blog/no-authentication-needed-magento-2-mirror.html
echo "Preparing project at $MAGE_FROM using $COMPOSER_FROM"
$COMPOSER_FROM create-project --repository=https://repo-magento-mirror.fooman.co.nz/ magento/project-community-edition=$MAGE_FROM ./instances/magento$ID/  --no-install
cd instances/magento$ID/
$COMPOSER_FROM config --unset repo.0
$COMPOSER_FROM config repositories.ampersandtestmodule '{"type": "path", "url": "./../../TestVendorModule/", "options": {"symlink":false}}'
$COMPOSER_FROM config repo.foomanmirror composer https://repo-magento-mirror.fooman.co.nz/
$COMPOSER_FROM config minimum-stability dev
$COMPOSER_FROM config prefer-stable true
$COMPOSER_FROM require ampersand/upgrade-patch-helper-test-module:"*" --no-update
for devpackage in $($COMPOSER_FROM show -s | sed -n '/requires (dev)$/,/^$/p' | grep -v 'requires (dev)' | cut -d ' ' -f1); do
  echo "$COMPOSER_FROM remove --dev $devpackage --no-update"
  $COMPOSER_FROM remove --dev $devpackage --no-update
done
if [ "$COMPOSER_FROM" == "composer2" ]; then
  $COMPOSER_FROM config --no-interaction allow-plugins.dealerdirect/phpcodesniffer-composer-installer true
  $COMPOSER_FROM config --no-interaction allow-plugins.laminas/laminas-dependency-plugin true
  $COMPOSER_FROM config --no-interaction allow-plugins.magento/* true
  $COMPOSER_FROM install --no-interaction
else
  $COMPOSER_FROM install --no-interaction --ignore-platform-reqs
fi

# Backup vendor
echo "mv vendor/ vendor_orig/"
mv vendor/ vendor_orig/

echo "setting php to version $PHP_TO and $COMPOSER_TO"
phpenv global $PHP_TO
php -v

echo "Upgrading magento to $MAGE_TO"
$COMPOSER_TO require magento/product-community-edition $MAGE_TO --no-update
if [ "$COMPOSER_TO" == "composer2" ]; then
  $COMPOSER_TO config --no-interaction allow-plugins.dealerdirect/phpcodesniffer-composer-installer true
  $COMPOSER_TO config --no-interaction allow-plugins.laminas/laminas-dependency-plugin true
  $COMPOSER_TO config --no-interaction allow-plugins.magento/* true
  $COMPOSER_TO update --with-all-dependencies --no-interaction
  $COMPOSER_TO install --no-interaction
else
  $COMPOSER_TO update composer/composer magento/product-community-edition --with-dependencies --ignore-platform-reqs
  $COMPOSER_TO install --no-interaction --ignore-platform-reqs
fi
# Spoof some changes into our "third party" test module so they appear in the diff
echo "<!-- -->"  >> vendor/ampersand/upgrade-patch-helper-test-module/src/module/view/frontend/templates/checkout/something.phtml
echo "//some change"  >> vendor/ampersand/upgrade-patch-helper-test-module/src/module/Model/SomeClass.php
echo "//some change"  >> vendor/ampersand/upgrade-patch-helper-test-module/src/module/Api/ExampleInterface.php
echo "//some change"  >> vendor/ampersand/upgrade-patch-helper-test-module/src/module/Api/ExampleTwoInterface.php

# Install test module and theme
echo "Installing test module"
cd -
cp -r TestModule/app/code ./instances/magento$ID/app/
cp -r TestModule/app/design/frontend/Ampersand ./instances/magento$ID/app/design/frontend/
cd -
if [ "$NODB" == "1" ]; then
  php bin/magento module:enable Ampersand_Test
  php bin/magento module:enable Ampersand_TestVendor
fi

if [ "$NODB" == "0" ]; then

  echo "Creating database testmagento$ID"
  mysql -uroot -h$HOSTNAME --port=9999 -e "drop database if exists testmagento$ID;" -vvv
  mysql -uroot -h$HOSTNAME --port=9999 -e "create database testmagento$ID;" -vvv

  echo "Test elasticsearch connectivity"
  ES_INSTALL_PARAM=''
  if curl http://$HOSTNAME:9200; then
    ES_INSTALL_PARAM=" --elasticsearch-host=$HOSTNAME "
  fi

  echo "Installing magento"
  # Install magento
  php -d memory_limit=1024M bin/magento setup:install \
      --admin-firstname=ampersand --admin-lastname=developer --admin-email=example@example.com \
      --admin-user=admin --admin-password=somepass123 \
      --db-name=testmagento$ID --db-user=root --db-host=$HOSTNAME:9999 $ES_INSTALL_PARAM \
      --backend-frontname=admin \
      --base-url=https://magento-$ID-develop.localhost/ \
      --language=en_GB --currency=GBP --timezone=Europe/London \
      --use-rewrites=1;

  # Set developer mode
  php bin/magento deploy:mode:set developer

  # See the comment in src/Ampersand/PatchHelper/Helper/Magento2Instance.php
  # This helps replicate a bug in which the tool exits with a 0 and no output
  php bin/magento config:set web/url/redirect_to_base 0
fi

echo "Generate patch file for analysis"
diff -ur vendor_orig/ vendor/ > vendor.patch || true

cd /src/
$COMPOSER_TO install --no-interaction
set +e
