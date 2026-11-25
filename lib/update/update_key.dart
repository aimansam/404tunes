/// Public half of the Ed25519 key that signs each release's update.json. The private half is the GitHub secret
/// UPDATE_SIGNING_KEY; it is not in this repository. tool/sign_update.sh refuses to sign with any other key.
const updatePublicKey = 'X6ssl74hu7hMNXIsK8W/kjqfB4mAzQtBIvYH0WB/SEM=';
