#!/usr/bin/env bash
# add_subs_min.sh  |  Usage: ./add_subs_min.sh <START_IMSI> <COUNT>

# Check args
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <START_IMSI> <COUNT>"
  echo "Example: $0 208950000000132 100"
  exit 1
fi

start="$1"
count="$2"

for ((i=0; i<count; i++)); do
  imsi=$(printf "%015d" $((10#$start + i)))
  echo "Inserting subscriber with IMSI: $imsi"
  docker exec -i mysql mysql -u test -ptest oai_db -e "
  INSERT INTO AuthenticationSubscription
  (ueid, authenticationMethod, encPermanentKey, protectionParameterId, sequenceNumber,
   authenticationManagementField, algorithmId, encOpcKey, encTopcKey, vectorGenerationInHss,
   n5gcAuthMethod, rgAuthenticationInd, supi)
  VALUES
  ('$imsi','5G_AKA','0C0A34601D4F07677303652C0462535B','0C0A34601D4F07677303652C0462535B',
   '{\"sqn\":\"000000000020\",\"sqnScheme\":\"NON_TIME_BASED\",\"lastIndexes\":{\"ausf\":0}}',
   '8000','milenage','63bfa50ee6523365ff14c1f45f88737d',NULL,NULL,NULL,NULL,'$imsi');
  "
done

echo "✅ Done: inserted $count subscriber(s) starting at IMSI $start"
