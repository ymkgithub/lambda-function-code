exports.handler = async (event) => {
    return {
        statusCode: 200,
        body: JSON.stringify('Testing the provisioned concurrency time for Function 1!. 123 testing Added resolution'),
    };
};
