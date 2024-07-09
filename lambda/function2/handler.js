exports.handler = async (event) => {
    return {
        statusCode: 200,
        body: JSON.stringify('Testing the provisioned concurrency for Function 2! testing the Added resolution'),
    };
};
