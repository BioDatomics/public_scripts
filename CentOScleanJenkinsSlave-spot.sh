#!/bin/bash -v
#Before using this script is necessary to install package:
#sudo apt-get install ec2-api-tools

#Jenkins starts this script from root "/". we need to fix it
cd
mkdir -p tmp
cd tmp

echo ssh -i ${KEY_PAIR}.pem 
ls 

exit
#ami for CentOS 6.4 with only root disk and cloud-init installed
#CentOS6.4 with cloud init on EBS storage : ami-1064f120
#CentOS6.4 with all packages for Ambari building: ami-47be2f77
AMI=$1
#AMI=ami-1064f120

PRICE=$2 #0.01; maximal price per unit/hour. 

#TYPE=hs1.8xlarge #m1.small. Amazon currently has strange low price for hs1.8xlarge
TYPE=$3 #hs1.8xlarge

REGION=us-west-2

#ZONE=us-west-2a #availability zone, need to be verified for better price
ZONE=$4
#KEY_PAIR=biodatomics-key
KEY_PAIR=/var/lib/jenkins/${5}

echo $KEY_PAIR
ls -lahs $KEY_PAIR
exit

#TAG_NAME="Jenkins Slave CentOS6.4"
TAG_NAME=$6

NUM_INSTANCES=$7

#SECURITY_GROUP='Hadoop-Development'
SECURITY_GROUP=$8

MAPPING='/dev/sdb=ephemeral0' #adding block device see "ec2-request-spot-instances -h"
REQUEST='one-time' #Specified the spot instance request type; either 'one-time' or 'persistent'.

#script below will be automatically started on instance after it activated. 
cat > script.txt << EOF
#!/bin/sh

#download slave jar
wget http://ci.biodt.org/jenkins/jnlpJars/slave.jar -O /home/ec2-user/slave.jar

#install oracle java
wget --no-check-certificate --no-cookies --header "Cookie: gpw_e24=http%3A%2F%2Fwww.oracle.com" "http://download.oracle.com/otn-pub/java/jdk/6u45-b06/jdk-6u45-linux-x64-rpm.bin" -O jdk-6u45-linux-x64-rpm.bin
chmod a+x jdk-6u45-linux-x64-rpm.bin 
./jdk-6u45-linux-x64-rpm.bin 
/usr/sbin/alternatives --install /usr/bin/java java /usr/java/jdk1.6.0_45/bin/java 20000

mount -t tmpfs -o size=50G tmpfs /home/ec2-user/ram 
chown -R ec2-user:ec2-user /home/ec2-user/ram

wget http://pkgs.repoforge.org/git/git-1.7.11.3-1.el6.rfx.x86_64.rpm http://pkgs.repoforge.org/git/perl-Git-1.7.11.3-1.el6.rfx.x86_64.rpm
yum -y install git-1.7.11.3-1.el6.rfx.x86_64.rpm perl-Git-1.7.11.3-1.el6.rfx.x86_64.rpm

EOF

SIR_REQUEST_TMP=`ec2-request-spot-instances -k $KEY_PAIR --region $REGION $AMI -n $NUM_INSTANCES -b $MAPPING -p $PRICE -t $TYPE \
    -r $REQUEST -z $ZONE --group $SECURITY_GROUP --user-data-file=script.txt`

SIR_REQUEST=`echo $SIR_REQUEST_TMP | cut -f 2 -d " " | grep sir-`
rm -f script.txt

echo $SIR_REQUEST

if [ -z $SIR_REQUEST ] ; then
	echo "Request wasn't placed due to error"
	echo used command: ec2-request-spot-instances -k $KEY_PAIR --region $REGION $AMI -n $NUM_INSTANCES -b $MAPPING -p $PRICE -t $TYPE -r $REQUEST -z $ZONE --group $SECURITY_GROUP --user-data-file=~/script.txt
	exit 1
fi

#Capture status of request. Initially request has STATUS=open and we need it to be active in order to continue
STATUS=`ec2-describe-spot-instance-requests --region $REGION | grep $SIR_REQUEST | cut -f 6 `

#We won't want to wait till infinity for instance to spawn up. Each count equal to 1 min
COUNT=20

#This variable checks if instance is spot or regular
IS_SPOT=1

#Wait for spot instance request to succeed.
REQUIRED_STATUS="active"
while [ $STATUS != $REQUIRED_STATUS ]
do
	echo "Waiting until order fullfilled. time before timeout: $COUNT"
	sleep 60
	STATUS=`ec2-describe-spot-instance-requests --region $REGION | grep $SIR_REQUEST | cut -f 6`
	if [ $COUNT -le 1 ]
	then
		IS_SPOT=0
		break
	fi
	COUNT=`expr $COUNT - 1`
	echo $COUNT
done

if [ $IS_SPOT -eq 1 ]
then
	INSTANCE_ID=`ec2-describe-spot-instance-requests  --region $REGION | grep $SIR_REQUEST | cut -f 12`
else
	#This part of "if" was not validated" Temproarry put exit
	#Kill spot instance request we made earlier
    
	ec2-cancel-spot-instance-requests --region $REGION $SIR_REQUEST
	exit 1
	#Spawn up a regular instance
	EC2_RESPONSE=`ec2-run-instances $AMI -n $NUM_INSTANCES -t $TYPE -k $KEY_PAIR --group $SECURITY_GROUP --region $REGION`
	INSTANCE_ID=`echo $EC2_RESPONSE | tail -1 | cut -f2`
	STATUS=`echo $EC2_RESPONSE | tail -1 | cut -f6`
	REQUIRED_STATUS="running"
	while [ $STATUS != $REQUIRED_STATUS ]
	do
		sleep 60
		STATUS=`ec2-describe-instances --region $REGION $INSTANCE_ID | tail -1 | cut -f6`
	done
fi

sleep 10

#Instance is now active. Capture data associated with instance like instance-id, external and internal dns.
DESCRIBE_INSTANCE=`ec2-describe-instances --region $REGION $INSTANCE_ID`
INSTANCE_EXTERNAL_DNS=`echo $DESCRIBE_INSTANCE | tail -1 | cut -s -f 8 -d " "`
INSTANCE_INTERNAL_HOSTNAME=`echo $DESCRIBE_INSTANCE | tail -1 | cut -s -f 9 -d " "`

#If we are not able to get internal hostname within next 2 minutes for some reason then quit
while [ -z $INSTANCE_INTERNAL_HOSTNAME ]
do
	COUNT=`expr $COUNT + 1 `
	sleep 10
	DESCRIBE_INSTANCE=`ec2-describe-instances --region $REGION $INSTANCE_ID`
	INSTANCE_EXTERNAL_DNS=`echo $DESCRIBE_INSTANCE | tail -1 | cut -s -f 8 -d " "`
	INSTANCE_INTERNAL_HOSTNAME=`echo $DESCRIBE_INSTANCE | tail -1 | cut -s -f 9 -d " "`
	if [ $COUNT -ge 12 ]
	then
		ec2-cancel-spot-instance-requests --region $REGION $SIR_REQUEST
		ec2-terminate-instances --region $REGION $INSTANCE_ID
		exit 1
	fi
done

ec2addtag --region $REGION $INSTANCE_ID --tag Name="$TAG_NAME" -t type="Jenkins SpotInstance slave"

RUN_TEST=`ssh -i ${KEY_PAIR}.pem -o "StrictHostKeyChecking no" -f -o ConnectTimeout=30 ec2-user@${INSTANCE_INTERNAL_HOSTNAME} java -version 2>&1| grep version`

#System should leave this cycle only when instance answered on ssh connection and java installed. 
COUNT=40
while [ -z "$RUN_TEST" ]
do
	COUNT=`expr $COUNT - 1`
	echo "Waiting until instance starts and java installed countdown : $COUNT"
	sleep 20
	RUN_TEST=`ssh -i ${KEY_PAIR}.pem -o "StrictHostKeyChecking no" -f -o ConnectTimeout=20 ec2-user@${INSTANCE_INTERNAL_HOSTNAME} java -version 2>&1| grep version`
	
	if [ $COUNT -le 1 ]
	then
		ec2-cancel-spot-instance-requests --region $REGION $SIR_REQUEST
		ec2-terminate-instances --region $REGION $INSTANCE_ID
		exit 1
	fi
done

ssh -i ${KEY_PAIR}.pem -o "StrictHostKeyChecking no" ec2-user@${INSTANCE_INTERNAL_HOSTNAME} java -jar /home/ec2-user/slave.jar
ssh -i ${KEY_PAIR}.pem -o "StrictHostKeyChecking no" ec2-user@${INSTANCE_INTERNAL_HOSTNAME} sudo shutdown -h now

ec2-cancel-spot-instance-requests --region $REGION $SIR_REQUEST
ec2-terminate-instances --region $REGION $INSTANCE_ID

